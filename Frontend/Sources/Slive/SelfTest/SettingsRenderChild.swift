import AppKit
import Combine
import SwiftUI

/// The Settings render suite's child process: `Slive --self-test --only
/// "Settings render" --settings-render-child <group> together|one <views>`.
/// Draws the views offscreen and reports on stdout, one `§R` line per
/// fact; the parent (`SettingsRenderTests`) judges.
@MainActor
enum RenderChild {
    nonisolated static let flag = "--settings-render-child"

    // MARK: - Parent side

    struct Report {
        var cases: [Int: SettingsRenderTests.Measure] = [:]
        var side: [String: Int] = [:]
        var finished = false
        /// The view a dead child was on, when it could tell.
        var culprit: Int?
        var death: String?
        /// Main-thread share while idle that no view's own layout accounts for.
        var unattributedCPU = 0.0
        /// Run-loop slices per idle window while every view sat together.
        var slices = 0
        /// SwiftUI faults logged while every view settled together.
        var unattributedFaults = 0
    }

    nonisolated static func launch(group: Int, cases: [Int], together: Bool) -> Report {
        let process = Process()
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--self-test", "--only", "Settings render", flag, "\(group)",
                             together ? "together" : "one", cases.map(String.init).joined(separator: ",")]
        // os_log mirrored to stderr (as under Xcode), into the same pipe:
        // SwiftUI's "Publishing changes from within view updates" fault then
        // lands between the lines of the view that caused it.
        var environment = ProcessInfo.processInfo.environment
        environment["OS_ACTIVITY_DT_MODE"] = "1"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.qualityOfService = .userInteractive   // performance cores, like a foreground app
        var report = Report()
        do { try process.run() } catch {
            report.death = "couldn't start a child: \(error)"
            return report
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + SettingsRenderTests.Limits.childSeconds, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        RenderFiles.removeLeftovers(of: process.processIdentifier)   // a child that died keeps its temp folder

        var current = -1
        var faults: [Int: Int] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.contains(SwiftUIFault.message) {
                faults[current, default: 0] += 1
                continue
            }
            guard line.hasPrefix("§R ") else { continue }
            let body = String(line.dropFirst(3))
            let words = body.split(separator: " ").map(String.init)
            let f = fields(words)
            switch words[0] {
            case "BEGIN": current = Int(words[1]) ?? -1
            case "SETTLE": current = -1
            case "HOST":
                guard let k = Int(words[1]) else { break }
                report.cases[k] = SettingsRenderTests.Measure(
                    first: double(f["first"]), publishes: Int(f["publishes"] ?? "") ?? 0, top: f["top"] ?? "",
                    cpuShare: double(f["cpu"]), relayouts: Int(f["relayouts"] ?? "") ?? 0,
                    ticks: Int(f["ticks"] ?? "") ?? 0, peakPublishes: Int(f["peakpub"] ?? "") ?? 0,
                    peakCPU: double(f["peakcpu"]), alone: f["alone"] == "1")
            case "CHUNK":
                report.unattributedCPU = double(f["unattributed"])
                report.slices = Int(f["slices"] ?? "") ?? 0
            case "SIDE": report.side[words[1]] = Int(words.count > 2 ? words[2] : "") ?? 0
            case "HANG", "LOOP":
                report.death = body
                report.culprit = Int(f["view"] ?? "").flatMap { $0 >= 0 ? $0 : nil }
            case "END": report.finished = true
            default: break
            }
        }
        for (k, n) in faults {
            if k >= 0, report.cases[k] != nil { report.cases[k]?.faults = n } else { report.unattributedFaults += n }
        }
        if !report.finished, report.death == nil {
            report.culprit = current >= 0 ? current : nil
            report.death = process.terminationReason == .uncaughtSignal
                ? "child crashed (signal \(process.terminationStatus))"
                : "child exited \(process.terminationStatus) without finishing"
        }
        return report
    }

    nonisolated private static func fields(_ words: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for word in words {
            let kv = word.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    nonisolated private static func double(_ s: String?) -> Double { s.flatMap(Double.init) ?? 0 }

    // MARK: - Child side

    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data(("§R " + line + "\n").utf8))
    }

    static func run(_ args: [String]) -> Never {
        let groups = SettingsRenderTests.groups
        guard args.count == 3, let g = Int(args[0]), groups.indices.contains(g) else {
            emit("HANG view=-1 bad arguments \(args)")
            exit(2)
        }
        let group = groups[g]
        let together = args[1] == "together"
        let indices = args[2].split(separator: ",").compactMap { Int($0) }.filter { group.cases.indices.contains($0) }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)   // no Dock icon, never active
        let probe = RenderProbe()
        probe.startWatchdog()
        let files = RenderFiles()
        let appSupport = AppSupportSnapshot()
        let defaults = DefaultsSnapshot()

        var side: [String: Int] = [:]
        func account(_ world: RenderWorld) {
            side["secretWrites", default: 0] += world.secrets.writes
            side["settingsWrites", default: 0] += world.settingsStore.writes
            side["fetches", default: 0] += world.engines.fetches
            side["loads", default: 0] += world.engines.loads
            side["playing", default: 0] += world.env.player.currentID == nil ? 0 : 1
            side["serverStarts", default: 0] += world.env.backend.status == .offline ? 0 : 1
        }

        if together {
            // Each view gets its own world, as in the app (one window, one
            // env): a publish re-renders only its own view.
            var worlds: [RenderWorld] = []
            var hosts: [RenderHost] = []
            for k in indices {
                emit("BEGIN \(k)")
                let world = makeWorld(group, group.cases[k], files)
                probe.watch(world.observed, view: k)
                let host = mount(group.cases[k], world, FixtureCounter(), probe, index: k)
                emit("DONE \(k)")
                worlds.append(world)
                hosts.append(host)
            }
            emit("SETTLE")
            let (perView, unattributed, slices) = settleAndMeasure(hosts, probe, attribute: true)
            for (host, m) in zip(hosts, perView) { emit("HOST \(host.index) first=\(fmt(host.first)) \(m)") }
            emit("CHUNK unattributed=\(fmt(unattributed)) slices=\(slices)")
            for host in hosts { host.tearDown() }
            probe.pump(0.05, hosts: [])
            for world in worlds {
                account(world)
                world.tearDown()
            }
        } else {
            for k in indices {
                emit("BEGIN \(k)")
                let world = makeWorld(group, group.cases[k], files)
                let counter = FixtureCounter()
                probe.unwatch()
                probe.watch(world.observed + [("FixtureCounter", counter.objectWillChange)], view: k)
                let host = mount(group.cases[k], world, counter, probe, index: k)
                emit("DONE \(k)")
                let (perView, _, _) = settleAndMeasure([host], probe, attribute: false)
                emit("HOST \(k) first=\(fmt(host.first)) \(perView[0])")
                host.tearDown()
                probe.pump(0.03, hosts: [])
                account(world)
                world.tearDown()
            }
        }
        side["peakPhasePublishes"] = probe.peakPhasePublishes
        side["defaultsChanges"] = defaults.changed() ? 1 : 0
        side["appSupportChanges"] = appSupport.changed() ? 1 : 0
        files.remove()
        for (k, v) in side.sorted(by: { $0.key < $1.key }) { emit("SIDE \(k) \(v)") }
        emit("END")
        exit(0)
    }

    static func makeWorld(_ group: SettingsRenderTests.Group, _ c: SettingsRenderTests.Case,
                          _ files: RenderFiles) -> RenderWorld {
        var flapping = false
        if case .fixture(let f) = c.host { flapping = f.flappingRegistry }
        let world = RenderWorld(group.state, capabilities: group.capabilities, files: files,
                                flappingRegistry: flapping)
        world.applyDefaults()
        world.settingsStore.resetWrites()
        return world
    }

    static func mount(_ c: SettingsRenderTests.Case, _ world: RenderWorld, _ counter: FixtureCounter,
                      _ probe: RenderProbe, index: Int) -> RenderHost {
        let env = world.env
        let layout = SliveLayout.tier(for: c.width)
        let view: AnyView
        switch c.host {
        case .shell(let id):
            view = AnyView(SettingsView(env: env, page: id))
        case .page(let id):
            let spec = SettingsRegistry.spec(id, for: env.capabilities)
            view = AnyView(ScrollView {
                spec.content(SettingsPageContext(env: env, open: { _ in }))
                    .frame(maxWidth: spec.width.cap(for: layout))
                    .padding(.horizontal, SliveTheme.gutter)
                    .frame(maxWidth: .infinity)
            }
            .environment(\.sliveLayout, layout)
            .background(SliveTheme.background))
        case .fixture(let f):
            view = f.view(world, counter: counter)
        }
        // Implicit and explicit animations off: a pulsing dot ticks every
        // frame by design, and loops don't need animations to show.
        // (TimelineView-driven ones still run.)
        let still = AnyView(view.transaction { $0.animation = nil; $0.disablesAnimations = true })
        probe.phase("mount", view: index)
        let host = RenderHost(still, size: NSSize(width: c.width, height: SliveTheme.windowDefault.height),
                              index: index)
        probe.phase("mounted", view: index)
        return host
    }

    /// Settles, then two idle windows. Per view, the quieter window is the
    /// verdict and the busier one the peak. `attribute`: several views share
    /// the main thread, so each one's CPU is the time spent laying it out;
    /// what's left over is returned as unattributed. Alone, a view's CPU is
    /// the whole thread's.
    static func settleAndMeasure(_ hosts: [RenderHost], _ probe: RenderProbe,
                                 attribute: Bool) -> (perView: [String], unattributed: Double, slices: Int) {
        probe.phase("settle", view: attribute ? -1 : hosts[0].index)
        probe.pump(SettingsRenderTests.Limits.settleSeconds, hosts: hosts)
        probe.phase("idle", view: attribute ? -1 : hosts[0].index)
        let a = probe.window(hosts), b = probe.window(hosts)
        var lines: [String] = []
        for (i, host) in hosts.enumerated() {
            let cpuA = attribute ? a.layoutCPU[i] / a.seconds : a.threadCPU / a.seconds
            let cpuB = attribute ? b.layoutCPU[i] / b.seconds : b.threadCPU / b.seconds
            let pubA = a.publishes[host.index] ?? (0, ""), pubB = b.publishes[host.index] ?? (0, "")
            let quiet = pubA.0 <= pubB.0 ? pubA : pubB
            lines.append("publishes=\(quiet.0) top=\(quiet.1.isEmpty ? "-" : quiet.1) cpu=\(fmt(min(cpuA, cpuB))) "
                         + "relayouts=\(min(a.relayouts[i], b.relayouts[i])) ticks=\(min(a.ticks, b.ticks)) "
                         + "peakpub=\(max(pubA.0, pubB.0)) peakcpu=\(fmt(max(cpuA, cpuB))) alone=\(attribute ? 0 : 1)")
        }
        let rest = { (w: RenderProbe.Window) in max(0, w.threadCPU - w.layoutCPU.reduce(0, +)) / w.seconds }
        return (lines, min(rest(a), rest(b)), min(a.ticks, b.ticks))
    }

    nonisolated static func fmt(_ x: Double) -> String { String(format: "%.4f", x) }
}

/// One view in an offscreen window that is never ordered in, so it is
/// never on screen and never key.
@MainActor
final class RenderHost {
    let window: NSWindow
    let view: NSView
    /// The view's index in its group.
    let index: Int
    /// Main-thread CPU seconds the first layout took (CPU, not wall time:
    /// a busy machine makes the wait longer, not the work).
    let first: Double

    init(_ root: AnyView, size: NSSize, index: Int) {
        self.index = index
        let hosting = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -40_000, y: -40_000), size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        view = hosting
        let c0 = RenderProbe.threadCPU()
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        first = RenderProbe.threadCPU() - c0
    }

    func tearDown() {
        window.contentView = nil
        window.close()
    }
}

/// Counts objectWillChange per view and object, pumps the main run loop,
/// and keeps a watchdog on the main thread: a phase that stops making
/// progress, or publishes without end, is reported and the child exits.
final class RenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var beat = DispatchTime.now().uptimeNanoseconds
    private var phaseName = "start"
    private var phaseView = -1
    private var phaseTotal = 0
    /// Per view, this phase — a loop is one view publishing without end.
    private var phaseByView: [Int: Int] = [:]
    private var phaseStart = Date()
    private var counts: [Int: [String: Int]] = [:]
    /// The most any view published in one phase (the legit ceiling).
    private(set) var peakPhasePublishes = 0
    private var subscriptions: [AnyCancellable] = []

    func startWatchdog() {
        let limit = UInt64(SettingsRenderTests.Limits.hangSeconds * 1e9)
        Thread.detachNewThread { [self] in
            while true {
                usleep(50_000)
                lock.lock()
                let stalled = DispatchTime.now().uptimeNanoseconds - beat
                let line = "HANG view=\(phaseView) no progress for \(String(format: "%.1f", Double(stalled) / 1e9)) s during \(phaseName) (\(phaseTotal) objectWillChange meanwhile)"
                lock.unlock()
                if stalled > limit {
                    FileHandle.standardOutput.write(Data(("§R " + line + "\n").utf8))
                    _exit(3)
                }
            }
        }
    }

    @MainActor func unwatch() { subscriptions = [] }

    @MainActor
    func watch(_ objects: [(String, ObservableObjectPublisher)], view: Int) {
        subscriptions += objects.map { name, publisher in
            publisher.sink { [unowned self] _ in self.published(view, name) }
        }
    }

    private func published(_ view: Int, _ name: String) {
        lock.lock()
        counts[view, default: [:]][name, default: 0] += 1
        phaseTotal += 1
        let n = phaseByView[view, default: 0] + 1
        phaseByView[view] = n
        peakPhasePublishes = max(peakPhasePublishes, n)
        if n > SettingsRenderTests.Limits.runawayPublishes {
            let line = "LOOP view=\(view) \(n) objectWillChange in \(String(format: "%.2f", Date().timeIntervalSince(phaseStart))) s during \(phaseName) (\(name) last)"
            FileHandle.standardOutput.write(Data(("§R " + line + "\n").utf8))
            _exit(4)
        }
        lock.unlock()
    }

    func phase(_ name: String, view: Int) {
        lock.lock()
        phaseName = name
        phaseView = view
        phaseTotal = 0
        phaseByView = [:]
        phaseStart = Date()
        beat = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    private func tick() {
        lock.lock(); beat = DispatchTime.now().uptimeNanoseconds; lock.unlock()
    }

    /// Runs the main run loop in ~4 ms slices (timers, main-queue work,
    /// SwiftUI's update observers), laying out each view that needs it after
    /// every slice, as the display cycle would.
    @MainActor @discardableResult
    func pump(_ seconds: Double, hosts: [RenderHost]) -> (ticks: Int, relayouts: [Int], layoutCPU: [Double]) {
        let end = Date().addingTimeInterval(seconds)
        var ticks = 0
        var relayouts = [Int](repeating: 0, count: hosts.count)
        var layoutCPU = [Double](repeating: 0, count: hosts.count)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.004)))
            for (i, host) in hosts.enumerated() where host.view.needsLayout {
                let c0 = Self.threadCPU()
                host.view.layoutSubtreeIfNeeded()
                layoutCPU[i] += Self.threadCPU() - c0
                relayouts[i] += 1
            }
            ticks += 1
            tick()
        }
        return (ticks, relayouts, layoutCPU)
    }

    struct Window {
        var seconds: Double
        var threadCPU: Double
        var ticks: Int
        var relayouts: [Int]
        var layoutCPU: [Double]
        /// Per view: its env's objectWillChange, and the busiest objects.
        var publishes: [Int: (Int, String)]
    }

    /// One idle window over `hosts`.
    @MainActor
    func window(_ hosts: [RenderHost]) -> Window {
        lock.lock(); counts = [:]; lock.unlock()
        let cpu0 = Self.threadCPU(), wall0 = Date()
        let p = pump(SettingsRenderTests.Limits.idleSeconds, hosts: hosts)
        let threadCPU = Self.threadCPU() - cpu0, seconds = Date().timeIntervalSince(wall0)
        lock.lock()
        let snapshot = counts
        lock.unlock()
        var publishes: [Int: (Int, String)] = [:]
        for (view, objects) in snapshot {
            let top = objects.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)×\($0.value)" }
            publishes[view] = (objects.values.reduce(0, +), top.joined(separator: ","))
        }
        return Window(seconds: seconds, threadCPU: threadCPU, ticks: p.ticks, relayouts: p.relayouts,
                      layoutCPU: p.layoutCPU, publishes: publishes)
    }

    static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
}

enum SwiftUIFault {
    static let message = "Publishing changes from within view updates"
}

/// This process's own persistent defaults domain — where `UserDefaults
/// .standard` writes land (and what reaches disk). In-memory domains
/// (registration, the argument domain the suite uses) don't count.
struct DefaultsSnapshot {
    private let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    private let before: NSDictionary?

    init() { before = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary? }

    func changed() -> Bool {
        (UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?) != before
    }
}

/// Modification dates of Slive's Application Support folders, to prove
/// nothing was created or removed in them.
struct AppSupportSnapshot {
    private let dates: [String: Date]

    init() { dates = Self.read() }

    func changed() -> Bool { Self.read() != dates }

    private static func read() -> [String: Date] {
        let root = AppSupport.root
        var out: [String: Date] = [:]
        for url in [root, root.appendingPathComponent("Models"), root.appendingPathComponent("Models/Custom"),
                    AppSupport.trainingDirectory, AppSupport.trainingDirectory.appendingPathComponent("audio")] {
            if let date = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
                out[url.path] = date
            }
        }
        return out
    }
}
