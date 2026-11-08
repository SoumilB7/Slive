import AppKit
import SwiftUI
import SliveTestKit

/// Opens Settings the way a user would — every registry page alone and in
/// the window shell, at every width tier, for Full and Lite, in several user
/// states — and fails on a view that never settles: a hang, runaway or
/// steady `objectWillChange`, a busy or never-idle main thread, a slow first
/// layout, or SwiftUI's "Publishing changes from within view updates".
///
/// Nov 13: a fresh install froze at 100% CPU the moment General opened —
/// `BalancedSuggestion.body` re-read the fine-tunes, which republished
/// `customModels`, which re-ran `body`, forever. No check had ever drawn
/// Settings with a new user's defaults.
///
/// The views render in child processes (`RenderChild`): a loop inside
/// SwiftUI's update never returns to its caller, so only a separate process
/// can be timed out and the view named. Each child draws a chunk of views
/// side by side, each with its own fake environment (`RenderWorld`: no
/// Keychain, server, model, download, audio, real defaults or Application
/// Support); a chunk that fails without naming a view is re-run one view at
/// a time.
@MainActor
enum SettingsRenderTests {
    static let suite = TestSuite(name: "Settings render") { t in
        print("[Settings render]")
        if let i = CommandLine.arguments.firstIndex(of: RenderChild.flag) {
            RenderChild.run(Array(CommandLine.arguments[(i + 1)...]))   // never returns
        }
        runParent(&t)
    }

    // MARK: - Thresholds (every run prints what it measured against them)

    enum Limits {
        /// Settle after mounting, before the idle windows.
        static let settleSeconds = 0.3
        /// Each of the two idle windows a settled view is measured over.
        static let idleSeconds = 0.25
        /// objectWillChange from one view's env objects per idle window.
        /// Settled views send 0; a loop sends thousands.
        static let publishes = 12
        /// Main-thread CPU spent on one view while idle, share of the window
        /// (beside other views: its own layouts; alone: the whole thread).
        /// Settled views ≤1%; the Training rail's 40 fps animation ~6%
        /// beside others, 13–24% alone; a loop 75–98%.
        static let cpuShare = 0.40
        /// Run-loop slices per idle window. An idle run loop waits out each
        /// ~4 ms slice (~60 per window); one that always has work queued
        /// (a loop through the main queue) returns at once, thousands of
        /// times — a sign that holds even when the machine is too busy for
        /// the CPU share to show it.
        static let slices = 190
        /// One view's first layout, in main-thread CPU seconds.
        static let firstLayoutSeconds = 2.0
        /// No progress on the main thread for this long (wall time) = a hang.
        /// Generous: a machine busy compiling stretches a heavy first layout.
        static let hangSeconds = 8.0
        /// More objectWillChange than this from one view in one phase (mount,
        /// settle, idle) = a runaway loop: the child stops at once instead of
        /// waiting out the hang. Settling views peak around 14.
        static let runawayPublishes = 1000
        /// Parent backstop per child process.
        static let childSeconds = 90.0
        /// Views per child (keeps the parallel children evenly loaded).
        static let chunk = 27
    }

    // MARK: - The matrix

    /// One window width per tier the shell and the registry's column caps
    /// switch on.
    nonisolated static let widths: [(SliveLayout, CGFloat)] = [
        (.compact, SliveTheme.windowMin.width),
        (.regular, SliveTheme.windowDefault.width),
        (.wide, SliveTheme.wideBreakpoint + 180),
    ]

    enum Host {
        /// A registry page alone, in a scroll view at the tier's cap.
        case page(SettingsPageID)
        /// The whole window: sidebar or compact chrome + the selected page.
        case shell(SettingsPageID)
        case fixture(RenderFixture)
    }

    struct Case {
        let host: Host
        let width: CGFloat
        var label: String {
            let tier = "\(SliveLayout.tier(for: width))"
            switch host {
            case .page(let id): return "\(id.rawValue) page @ \(tier)"
            case .shell(let id): return "shell+\(id.rawValue) @ \(tier)"
            case .fixture(let f): return f.rawValue
            }
        }
    }

    struct Group {
        let name: String
        let state: RenderState
        let capabilities: Capabilities
        let cases: [Case]
        /// Fixtures render one at a time (several are meant to loop).
        let oneAtATime: Bool
    }

    nonisolated static let full = Capabilities(hasServer: true)
    nonisolated static let lite = Capabilities(hasServer: false)

    /// Every state × Full, a new and a configured user × Lite; in each,
    /// every page the edition's registry lists, alone and in the shell, at
    /// every tier. Then the fixtures.
    nonisolated static let groups: [Group] = {
        func cases(_ caps: Capabilities) -> [Case] {
            let specs = SettingsRegistry.pages(for: caps)
            return widths.flatMap { _, width in
                specs.map { Case(host: .page($0.id), width: width) }
                    + specs.map { Case(host: .shell($0.id), width: width) }
            }
        }
        var groups = RenderState.allCases.map {
            Group(name: "\($0.rawValue) · Full", state: $0, capabilities: full, cases: cases(full), oneAtATime: false)
        }
        groups += [RenderState.fresh, .configured].map {
            Group(name: "\($0.rawValue) · Lite", state: $0, capabilities: lite, cases: cases(lite), oneAtATime: false)
        }
        groups.append(Group(name: "fixtures", state: .fresh, capabilities: full,
                            cases: RenderFixture.allCases.map { Case(host: .fixture($0), width: 640) },
                            oneAtATime: true))
        return groups
    }()

    // MARK: - Verdicts

    /// One view as measured: the quieter of its two idle windows (a loop is
    /// sustained), plus the busier one for the record.
    struct Measure {
        var first = 0.0
        var publishes = 0
        var top = ""
        var cpuShare = 0.0
        var relayouts = 0
        var ticks = 0
        var peakPublishes = 0
        var peakCPU = 0.0
        /// Measured alone (its own run loop), not beside other views.
        var alone = false
        /// SwiftUI's "Publishing changes from within view updates".
        var faults = 0
        /// HANG / LOOP / crash text when its child never finished it.
        var died: String?

        var violations: [String] {
            if let died { return [died] }
            var v: [String] = []
            if publishes > Limits.publishes { v.append("\(publishes) objectWillChange per idle window (\(top))") }
            if cpuShare > Limits.cpuShare { v.append(String(format: "main thread %.0f%% busy while idle", cpuShare * 100)) }
            if alone, ticks > Limits.slices { v.append("main run loop never idle (\(ticks) slices per window)") }
            if first > Limits.firstLayoutSeconds { v.append(String(format: "first layout took %.2f s", first)) }
            if faults > 0 { v.append("\(faults)× \"\(SwiftUIFault.message)\"") }
            return v
        }

        /// Re-laid out on most idle ticks but cheaply: an animation.
        var animates: Bool { ticks > 0 && relayouts * 2 > ticks }

        var summary: String {
            String(format: "%d publishes, cpu %.0f%%, %d/%d re-layouts", publishes, cpuShare * 100, relayouts, ticks)
        }
    }

    struct Outcome {
        var cases: [Int: Measure] = [:]
        var side: [String: Int] = [:]
        var childRuns = 0
        /// Worst whole-chunk main-thread share that no single view explains.
        var unattributedCPU = 0.0
        /// Most run-loop slices in a chunk's idle window.
        var slices = 0
    }

    // MARK: - Parent

    static func runParent(_ t: inout Checks) {
        let started = Date()
        for (tier, width) in widths {
            t.check(SliveLayout.tier(for: width) == tier, "render: \(Int(width)) pt is the \(tier) tier")
        }

        // Jobs: chunks of views, fixtures first (slowest per view).
        var jobs: [(group: Int, cases: [Int])] = []
        for (g, group) in groups.enumerated() {
            let chunk = group.oneAtATime ? group.cases.count : Limits.chunk
            for start in stride(from: 0, to: group.cases.count, by: chunk) {
                jobs.append((g, Array(start..<min(start + chunk, group.cases.count))))
            }
        }
        jobs.sort { groups[$0.group].oneAtATime && !groups[$1.group].oneAtATime }

        let workers = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        let lock = NSLock()
        var outcomes = [Outcome](repeating: Outcome(), count: groups.count)
        let gate = DispatchSemaphore(value: workers)
        let all = DispatchGroup()
        for job in jobs {
            gate.wait()
            all.enter()
            Thread.detachNewThread {
                let o = runChunk(job.group, job.cases)
                lock.lock()
                outcomes[job.group].cases.merge(o.cases) { $1 }
                for (k, v) in o.side {
                    outcomes[job.group].side[k] = k == "peakPhasePublishes"
                        ? max(outcomes[job.group].side[k] ?? 0, v) : (outcomes[job.group].side[k] ?? 0) + v
                }
                outcomes[job.group].childRuns += o.childRuns
                outcomes[job.group].unattributedCPU = max(outcomes[job.group].unattributedCPU, o.unattributedCPU)
                outcomes[job.group].slices = max(outcomes[job.group].slices, o.slices)
                lock.unlock()
                gate.signal()
                all.leave()
            }
        }
        all.wait()

        // Coverage: every registry page drawn, alone and in the shell, at
        // every tier, in every state of its edition.
        for caps in [full, lite] {
            let expected = Set(SettingsRegistry.pages(for: caps).map(\.id.rawValue))
            var drawn: [String: Int] = [:]
            var states = 0
            for (g, group) in groups.enumerated() where group.capabilities == caps && !group.oneAtATime {
                states += 1
                for (c, m) in outcomes[g].cases where m.died == nil {
                    switch group.cases[c].host {
                    case .page(let id): drawn["\(id.rawValue) page", default: 0] += 1
                    case .shell(let id): drawn["\(id.rawValue) shell", default: 0] += 1
                    case .fixture: break
                    }
                }
            }
            let short = expected.flatMap { ["\($0) page", "\($0) shell"] }
                .filter { drawn[$0, default: 0] < widths.count * states }.sorted()
            let name = caps == full ? "Full" : "Lite"
            t.check(short.isEmpty,
                    "render: every \(name) registry page drawn alone and in the shell, \(widths.count) tiers × \(states) states (\(expected.count) pages)",
                    "not drawn everywhere: \(short)")
        }

        // Every group settles.
        var all_: [Measure] = []
        for (g, group) in groups.enumerated() where !group.oneAtATime {
            let o = outcomes[g]
            let measures = group.cases.indices.compactMap { o.cases[$0] }
            all_ += measures
            var problems: [String] = []
            let missing = group.cases.count - measures.count
            if missing > 0 { problems.append("\(missing) views never measured") }
            for c in group.cases.indices {
                guard let m = o.cases[c], !m.violations.isEmpty else { continue }
                problems.append("\(group.cases[c].label): \(m.violations.joined(separator: "; "))")
            }
            if o.unattributedCPU > Limits.cpuShare, problems.isEmpty {
                problems.append(String(format: "%.0f%% main-thread CPU while idle that no single view shows",
                                       o.unattributedCPU * 100))
            }
            let animating = Set(group.cases.indices.filter { o.cases[$0]?.animates == true }
                .map { group.cases[$0].label.components(separatedBy: " @ ")[0] }).sorted()
            let summary = String(format: "%d views · idle max %d publishes, cpu %.0f%% · first layout max %.0f ms",
                                 group.cases.count, measures.map(\.publishes).max() ?? 0,
                                 (measures.map(\.cpuShare).max() ?? 0) * 100,
                                 (measures.map(\.first).max() ?? 0) * 1000)
                + (animating.isEmpty ? "" : " · animating: \(animating.joined(separator: ", "))")
            t.check(problems.isEmpty, "render: \(group.name) settles (\(summary))",
                    problems.joined(separator: " | "))
        }

        // The fixtures prove each detector fires, and stays quiet.
        if let g = groups.firstIndex(where: \.oneAtATime) {
            for (c, fixture) in RenderFixture.allCases.enumerated() {
                let m = outcomes[g].cases[c] ?? Measure(died: "never ran")
                let flagged = !m.violations.isEmpty
                t.check(flagged == fixture.flagged,
                        "render fixture: \(fixture.rawValue) \(fixture.flagged ? "is flagged" : "passes") (\(flagged ? m.violations.joined(separator: "; ") : m.summary))")
            }
        }

        // Rendering had no side effects (counted by the fakes in each child).
        var side: [String: Int] = [:]
        for g in groups.indices where !groups[g].oneAtATime {
            for (k, v) in outcomes[g].side where k != "peakPhasePublishes" { side[k, default: 0] += v }
            side["peakPhasePublishes"] = max(side["peakPhasePublishes"] ?? 0, outcomes[g].side["peakPhasePublishes"] ?? 0)
        }
        let views = groups.filter { !$0.oneAtATime }.reduce(0) { $0 + $1.cases.count }
        for (key, name) in [
            ("secretWrites", "no Keychain / secret writes"),
            ("settingsWrites", "no settings writes"),
            ("defaultsChanges", "no UserDefaults writes"),
            ("appSupportChanges", "Application Support untouched"),
            ("fetches", "no model downloads"),
            ("serverStarts", "the local server never started"),
            ("playing", "no audio played"),
        ] {
            t.equal(side[key] ?? 0, 0, "render: \(name) across \(views) views")
        }

        let firsts = all_.map(\.first).sorted()
        print(String(format: "  · %d views, %d child runs, %.1f s · first layout (CPU) median %.0f ms, max %.0f ms (limit %.0f) · idle publishes max %d (peak %d, limit %d) · idle cpu max %.0f%% (peak %.0f%%, limit %.0f%%) · settling publishes per view max %d (runaway %d) · chunk-wide: cpu no view explains max %.0f%%, run-loop slices per window max %d (limit %d) · fake model loads %d",
                     views + RenderFixture.allCases.count, outcomes.reduce(0) { $0 + $1.childRuns },
                     Date().timeIntervalSince(started),
                     (firsts.isEmpty ? 0 : firsts[firsts.count / 2]) * 1000, (firsts.last ?? 0) * 1000,
                     Limits.firstLayoutSeconds * 1000,
                     all_.map(\.publishes).max() ?? 0, all_.map(\.peakPublishes).max() ?? 0, Limits.publishes,
                     (all_.map(\.cpuShare).max() ?? 0) * 100, (all_.map(\.peakCPU).max() ?? 0) * 100,
                     Limits.cpuShare * 100, side["peakPhasePublishes"] ?? 0, Limits.runawayPublishes,
                     (outcomes.indices.filter { !groups[$0].oneAtATime }.map { outcomes[$0].unattributedCPU }.max() ?? 0) * 100,
                     outcomes.indices.filter { !groups[$0].oneAtATime }.map { outcomes[$0].slices }.max() ?? 0,
                     Limits.slices,
                     side["loads"] ?? 0))
    }

    /// Draws `cases` side by side in one child; when a child dies on a view
    /// it names, re-runs the rest without it; when it can't name one, or
    /// the chunk was busy without any one view being so, re-runs the rest
    /// one view at a time.
    nonisolated static func runChunk(_ g: Int, _ cases: [Int]) -> Outcome {
        var outcome = Outcome()
        var together = !groups[g].oneAtATime
        var left = cases
        while !left.isEmpty {
            let r = RenderChild.launch(group: g, cases: left, together: together)
            outcome.childRuns += 1
            for (k, m) in r.cases { outcome.cases[k] = m }
            for (k, v) in r.side {
                outcome.side[k] = k == "peakPhasePublishes" ? max(outcome.side[k] ?? 0, v) : (outcome.side[k] ?? 0) + v
            }
            left.removeAll { r.cases[$0] != nil }
            outcome.slices = max(outcome.slices, r.slices)
            outcome.unattributedCPU = max(outcome.unattributedCPU, r.unattributedCPU)
            if r.finished {
                if together, r.unattributedCPU > Limits.cpuShare || r.slices > Limits.slices || r.unattributedFaults > 0 {
                    // Busy (or a fault) that no view accounts for: one at a time.
                    together = false
                    left = cases
                    outcome.cases = [:]
                    continue
                }
                break
            }
            if let dead = r.culprit {
                outcome.cases[dead] = Measure(died: r.death ?? "child died")
                left.removeAll { $0 == dead }
            } else {
                together = false   // died with no view to blame
            }
        }
        return outcome
    }
}

// MARK: - Fixtures

/// Views that prove the detectors work: four misbehave on purpose, the
/// rest must pass. Rendered one at a time, quiet ones first (a looping
/// fixture ends its child process).
enum RenderFixture: String, CaseIterable {
    /// Draws an observed value; nothing else.
    case wellBehaved = "well-behaved view"
    /// The real BalancedSuggestion on tiny.en.
    case balancedSuggestion = "BalancedSuggestion on tiny.en"
    /// …with a fine-tune registry that changes on every read.
    case balancedSuggestionFlapping = "BalancedSuggestion on tiny.en, registry republishing on every read"
    /// The pre-745b444 body (disk check in `body`) with today's
    /// publish-on-change registry: 4df6e9f alone already stopped the loop.
    case oldBalancedSuggestionStable = "pre-745b444 BalancedSuggestion, publish-on-change registry"
    /// `body` publishes once, then never again: no loop, but SwiftUI logs it.
    case publishOnceFromBody = "one publish from body"
    /// onAppear / onChange flip @State forever (no ObservableObject).
    case stateFlipLoop = "@State flipped in onChange/onAppear"
    /// `body` assigns a @Published value every time — the Nov 13 shape.
    case republishFromBody = "republish from body (Nov 13 pattern)"
    /// The pre-745b444 body with a registry that changes on every read
    /// (≡ refreshCustomModels' unconditional assignment before 4df6e9f).
    case oldBalancedSuggestion = "pre-745b444 BalancedSuggestion, registry republishing on every read"

    var flagged: Bool {
        switch self {
        case .publishOnceFromBody, .stateFlipLoop, .republishFromBody, .oldBalancedSuggestion: return true
        default: return false
        }
    }

    var flappingRegistry: Bool { self == .balancedSuggestionFlapping || self == .oldBalancedSuggestion }

    @MainActor
    func view(_ world: RenderWorld, counter: FixtureCounter) -> AnyView {
        let transcription = world.env.transcription
        let model = Binding<String>(get: { WhisperCatalog.tiny }, set: { _ in })
        switch self {
        case .wellBehaved: return AnyView(WellBehaved(counter: counter))
        case .republishFromBody: return AnyView(RepublishFromBody(counter: counter))
        case .stateFlipLoop: return AnyView(StateFlipLoop())
        case .publishOnceFromBody: return AnyView(PublishOnceFromBody(counter: counter))
        case .balancedSuggestion, .balancedSuggestionFlapping:
            return AnyView(VStack { BalancedSuggestion(transcription: transcription, model: model) })
        case .oldBalancedSuggestion, .oldBalancedSuggestionStable:
            return AnyView(VStack { OldBalancedSuggestion(transcription: transcription, model: model) })
        }
    }
}

final class FixtureCounter: ObservableObject {
    @Published var value = 0
    var published = false
}

private struct WellBehaved: View {
    @ObservedObject var counter: FixtureCounter
    var body: some View { Text("value \(counter.value)") }
}

private struct RepublishFromBody: View {
    @ObservedObject var counter: FixtureCounter
    var body: some View {
        counter.value += 1
        return Text("value \(counter.value)")
    }
}

private struct PublishOnceFromBody: View {
    @ObservedObject var counter: FixtureCounter
    var body: some View {
        if !counter.published {
            counter.published = true
            counter.value += 1
        }
        return Text("value \(counter.value)")
    }
}

private struct StateFlipLoop: View {
    @State private var flag = false
    var body: some View {
        Text(flag ? "on" : "off")
            .onAppear { flag.toggle() }
            .onChange(of: flag) { _, _ in DispatchQueue.main.async { flag.toggle() } }
    }
}

/// BalancedSuggestion's gate as it was before 745b444: the on-disk check in
/// `body`.
private struct OldBalancedSuggestion: View {
    @ObservedObject var transcription: TranscriptionModel
    @Binding var model: String

    var body: some View {
        if ["tiny.en", "base.en"].contains(model), !transcription.isDownloaded(ModelCatalog.balanced) {
            Text("Whisper – large-v3 turbo is far more accurate · 600 MB")
        }
    }
}
