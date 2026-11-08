import Foundation
import SliveTestKit

/// Model residency under every pick and disk state: the real
/// `ModelResidency.refresh` / `modelReady` drive a simulated loader (one
/// compile at a time, as macOS does) until nothing is loading, and the
/// invariants are checked along the way. Picks come from `ModelCatalog`,
/// so a new model or engine joins the matrix by itself. Plus the
/// tier × RAM facts the loads read.
@MainActor
enum ResidencyMatrixTests {
    static let suite = TestSuite(name: "Residency matrix") { t in
        print("[Residency matrix]")
        simulate(&t)
        regressions(&t)
        failedDownloads(&t)
        tiersAndMemory(&t)
    }

    // MARK: - Dimensions

    /// A model's place on this Mac before launch.
    enum Disk: CaseIterable {
        case missing, onDisk, failing, coolingDown, downloading
    }

    static let fineTune = "slive-ft-matrix"
    static func picks(for use: ModelUse) -> [String] {
        ModelCatalog.all.filter { $0.uses.contains(use) }.map(\.id) + [fineTune]
    }

    struct Scenario: CustomStringConvertible {
        var dictation = ModelCatalog.defaultDictation
        var continuous = ModelCatalog.defaultContinuous
        var continuousOn = false
        var dictationDisk = Disk.onDisk
        var continuousDisk = Disk.onDisk
        /// Every other Parakeet (a possible stand-in).
        var otherParakeets = Disk.missing
        /// The user switched from a model that's loaded and serving.
        var previousServes = false

        var description: String {
            "dictation=\(dictation)(\(dictationDisk)) continuous=\(continuous)(\(continuousDisk)) "
                + "on=\(continuousOn) parakeets=\(otherParakeets) prev=\(previousServes)"
        }
    }

    static var dimensions: [[(inout Scenario) -> Void]] {
        [
            picks(for: .dictation).map { v in { $0.dictation = v } },
            picks(for: .continuous).map { v in { $0.continuous = v } },
            [false, true].map { v in { $0.continuousOn = v } },
            Disk.allCases.map { v in { $0.dictationDisk = v } },
            Disk.allCases.map { v in { $0.continuousDisk = v } },
            [Disk.missing, .onDisk, .failing].map { v in { $0.otherParakeets = v } },
            [false, true].map { v in { $0.previousServes = v } },
        ]
    }

    static let strength = 4

    // MARK: - Simulation

    private static func simulate(_ t: inout Checks) {
        let dims = dimensions
        let sizes = dims.map(\.count)
        let rows = CoveringArray.rows(sizes, strength: strength)
        t.check(CoveringArray.covers(rows, sizes, strength: strength),
                "\(rows.count) scenarios cover every \(strength)-way combination of picks and disk states "
                    + "(\(sizes.reduce(1, *)) in the full product)")
        var failures: [String: [String]] = [:]
        var order: [String] = []
        for row in rows {
            var scenario = Scenario()
            for (d, v) in row.enumerated() { dims[d][v](&scenario) }
            let first = Run(scenario, tier: .relaxed)
            var verdicts = first.judge()
            // Same picks, same disk, another tier: the same loads in the same order.
            let again = Run(scenario, tier: .feather)
            // (Downloads are fire-and-forget tasks: compared as a set.)
            verdicts.append(("the plan is deterministic and independent of the speed tier",
                             again.plan == first.plan && Set(again.events) == Set(first.events)))
            for (name, ok) in verdicts {
                if !order.contains(name) { order.append(name) }
                if !ok { failures[name, default: []].append(scenario.description) }
            }
        }
        for name in order {
            let failed = failures[name] ?? []
            t.check(failed.isEmpty, name,
                    "\(failed.count)/\(rows.count), e.g. " + failed.prefix(3).joined(separator: " | "))
        }
    }

    /// One launch (or model switch) carried out to the end.
    @MainActor final class Run {
        let scenario: Scenario
        let host: Host
        let residency: ModelResidency
        let previous: String?
        private(set) var events: [String] = []
        /// Loads, readies, failures and evictions in order.
        var plan: [String] { events.filter { !$0.hasPrefix("download ") } }
        private(set) var violations: [String] = []
        /// Spawned by residency, not started yet / started and unfinished.
        private var jobs: [@MainActor () async -> Void] = []
        private var running = 0

        /// One in-memory Settings for every run (its init reads the real
        /// login-item state, ~50 ms a time); each run sets what it varies.
        static let settings = Settings(store: InMemoryStore())

        init(_ scenario: Scenario, tier: SpeedTier) {
            self.scenario = scenario
            let s = Self.settings
            s.speedTier = tier.rawValue
            s.streamHoldOn = true
            s.streamToggleOn = false
            s.streamHotkey = scenario.continuousOn ? .fnDefault : nil
            host = Host()
            var spawned: (@escaping @MainActor () async -> Void) -> Void = { _ in }
            residency = ModelResidency(whisper: host, settings: s, spawn: { spawned($0) })
            let parakeets = ModelCatalog.ids(of: .parakeet)
            for id in parakeets where id != scenario.dictation && id != scenario.continuous {
                host.place(id, scenario.otherParakeets)
            }
            host.place(scenario.continuous, scenario.continuousDisk)
            host.place(scenario.dictation, scenario.dictationDisk)   // dictation's wins if they're one model

            // The user switched from a model that's loaded and serving: it
            // was the pick for both, then the picks changed.
            previous = scenario.previousServes
                ? ModelCatalog.ids(of: .whisper).first { $0 != scenario.dictation && $0 != scenario.continuous }
                : nil
            if let previous {
                host.place(previous, .onDisk)
                host.resident.insert(previous)
                host.statuses[previous] = .ready
                s.whisperModel = previous
                s.continuousModel = previous
                residency.modelReady(previous)
            }
            spawned = { [weak self] in self?.jobs.append($0) }
            host.observer = { [weak self] in self?.observe($0) }
            host.onReady = { [weak residency] in residency?.modelReady($0) }
            host.onFailed = { [weak residency] in residency?.modelFailed($0) }
            s.whisperModel = scenario.dictation
            s.continuousModel = scenario.continuous
            host.events.removeAll()
            var done = false
            Task { @MainActor in
                await self.drive()
                done = true
            }
            while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
            events = host.events
        }

        /// Launch, then finish the loads one at a time until none is left.
        private func drive() async {
            residency.refresh()
            await drain()
            var steps = 0
            while !host.queue.isEmpty, steps < 30 {
                host.finishNextLoad()
                await drain()
                steps += 1
            }
        }

        /// Run what residency spawned (the stand-in's `awaitReady → refresh`,
        /// downloads), in order, until every job left is parked on a load.
        private func drain() async {
            for _ in 0..<10_000 {   // bounded: a job that never parks fails the checks, not the run
                while !jobs.isEmpty {
                    let job = jobs.removeFirst()
                    running += 1
                    Task { @MainActor in
                        await job()
                        self.running -= 1
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000)
                if jobs.isEmpty, running == host.parked { return }
            }
        }

        /// Checked as it happens: what the dictation pick is served by when a
        /// model is evicted or a load starts.
        private func observe(_ event: Host.Event) {
            let pick = scenario.dictation
            switch event {
            case .evict(let model):
                if model == residency.servingDictationModel, !host.isReady(pick) {
                    violations.append("evicted the serving \(model) before \(pick) was ready")
                }
            case .load(let model):
                let planned = [pick, scenario.continuous, previous].compactMap { $0 }
                let standIn = ModelCatalog.engine(of: pick) == .whisper
                    && ModelCatalog.engine(of: model) == .parakeet && host.isDownloaded(model)
                    && !host.isReady(pick)
                if !planned.contains(model) && !standIn { violations.append("loaded unplanned \(model)") }
                if model == scenario.continuous, model != pick, !scenario.continuousOn, !standIn {
                    violations.append("loaded the continuous model with continuous off")
                }
            }
        }

        func judge() -> [(String, Bool)] {
            let s = scenario
            let pick = s.dictation
            let healthy: (Disk) -> Bool = { $0 == .onDisk }
            let loads = events.filter { $0.hasPrefix("load ") }
            func firstLoad(_ m: String) -> Int? { loads.firstIndex(of: "load \(m)") }
            let serving = residency.servingDictationModel
            let dictationServed = host.isReady(pick) || serving.map(host.isReady) == true
            let continuousDisk = s.continuous == pick ? s.dictationDisk : s.continuousDisk
            func parakeets(_ ok: (Disk) -> Bool) -> Bool {
                ModelCatalog.engine(of: pick) == .whisper && ModelCatalog.ids(of: .parakeet).contains { id in
                    ok(id == s.continuous ? continuousDisk : s.otherParakeets)
                }
            }
            // A stand-in is tried for a Whisper pick when a Parakeet is on
            // disk — not behind the pick's own running download (by design).
            let standInTried = s.dictationDisk != .downloading && parakeets { $0 == .onDisk || $0 == .failing }
            let parakeetCouldStandIn = s.dictationDisk != .downloading && parakeets(healthy)
            let anyUsable = healthy(s.dictationDisk) || s.previousServes || parakeetCouldStandIn
            let continuousHealthy = healthy(continuousDisk)
            let allowed: Set<String> = Set([pick, s.continuousOn ? s.continuous : nil, serving,
                                             s.continuousOn ? residency.servingContinuousModel : nil]
                                                .compactMap { $0 })

            var out: [(String, Bool)] = []
            out.append(("dictation is never left without a model while one on disk can serve",
                         !anyUsable || dictationServed))
            out.append(("a healthy dictation pick ends loaded and serving",
                         !healthy(s.dictationDisk) || (host.isReady(pick) && serving == pick)))
            out.append(("the serving model stays until its replacement is ready (and only stand-ins load early)",
                         violations.isEmpty))
            out.append(("dictation loads before the continuous model (a Parakeet stand-in excepted)",
                         { () -> Bool in
                             guard s.continuousOn, s.continuous != pick, let c = firstLoad(s.continuous),
                                   let d = firstLoad(pick) else { return true }
                             return d < c || standInTried
                         }()))
            // (A downloading dictation pick holds it back until its download
            // ends and loads — not simulated here.)
            out.append(("continuous on: a healthy continuous model ends loaded",
                         !(s.continuousOn && continuousHealthy && s.dictationDisk != .downloading)
                             || host.isReady(s.continuous)))
            out.append(("nothing stays resident that no pick needs",
                         host.resident.isSubset(of: allowed)))
            out.append(("the continuous model is fetched only when continuous is on and it's missing",
                         events.filter { $0.hasPrefix("download ") }.allSatisfy { $0 == "download \(s.continuous)" }
                             && (s.continuousOn && continuousDisk == .missing
                                 ? events.contains("download \(s.continuous)") : !events.contains { $0.hasPrefix("download ") })))
            out.append(("a failed or missing pick never loads, a cooling-down one waits",
                         [Disk.missing, .coolingDown, .downloading].contains(s.dictationDisk) ? firstLoad(pick) == nil : true))
            return out
        }
    }

    /// `TranscriptionModel` as residency sees it: loads queue and finish one
    /// at a time (macOS compiles one model at a time); a failing model's
    /// load fails and cools down.
    @MainActor final class Host: ResidentModels {
        enum Event { case evict(String), load(String) }

        var downloaded: Set<String> = []
        var failing: Set<String> = []
        var cooling: Set<String> = []
        var resident: Set<String> = []
        var statuses: [String: ModelStatus] = [:]
        private(set) var queue: [String] = []
        private var waiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
        /// `awaitReady` callers waiting on a load.
        var parked: Int { waiters.values.reduce(0) { $0 + $1.count } }
        var events: [String] = []
        var observer: ((Event) -> Void)?
        var onReady: ((String) -> Void)?
        var onFailed: ((String) -> Void)?

        func place(_ model: String, _ disk: Disk) {
            downloaded.remove(model); failing.remove(model); cooling.remove(model); statuses[model] = nil
            switch disk {
            case .missing: break
            case .onDisk: downloaded.insert(model)
            case .failing: downloaded.insert(model); failing.insert(model)
            case .coolingDown:
                downloaded.insert(model); failing.insert(model); cooling.insert(model)
                statuses[model] = .failed("Timed out")
            case .downloading: statuses[model] = .downloading(0.5)
            }
        }

        func isReady(_ model: String) -> Bool { resident.contains(model) }
        func status(for model: String) -> ModelStatus { statuses[model] ?? .notDownloaded }
        func isDownloaded(_ model: String) -> Bool { downloaded.contains(model) || resident.contains(model) }

        func retainModels(_ keep: Set<String>) {
            for model in resident.sorted() where !keep.contains(model) {
                observer?(.evict(model))
                resident.remove(model)
                statuses[model] = nil
                events.append("evict \(model)")
            }
        }

        /// As `TranscriptionModel.select`.
        func select(_ model: String) {
            if resident.contains(model) { statuses[model] = .ready; return }
            if queue.contains(model) { return }
            switch status(for: model) {
            case .downloading: return
            case .failed where cooling.contains(model) || !isDownloaded(model): return
            default: break
            }
            if isDownloaded(model) {
                statuses[model] = .preparing("Loading")
                startLoad(model)
            } else {
                statuses[model] = .notDownloaded
            }
        }

        private func startLoad(_ model: String) {
            guard !cooling.contains(model) else { return }
            observer?(.load(model))
            queue.append(model)
            events.append("load \(model)")
        }

        func awaitReady(_ model: String) async -> Bool {
            if resident.contains(model) { return true }
            guard isDownloaded(model) else { select(model); return false }
            if !queue.contains(model) { startLoad(model) }
            guard queue.contains(model) else { return false }   // cooling down
            return await withCheckedContinuation { waiters[model, default: []].append($0) }
        }

        func applySpeedTier(tierPicked: Bool) {}

        func download(_ model: String, options: LoadOptions) async {
            events.append("download \(model)")
            statuses[model] = .downloading(0)
        }

        /// The oldest load finishes: ready (→ `onModelReady`) or failed.
        func finishNextLoad() {
            let model = queue.removeFirst()
            let ok = !failing.contains(model)
            if ok {
                resident.insert(model)
                statuses[model] = .ready
                events.append("ready \(model)")
            } else {
                cooling.insert(model)
                statuses[model] = .failed("Timed out")
                events.append("failed \(model)")
            }
            for waiter in waiters.removeValue(forKey: model) ?? [] { waiter.resume(returning: ok) }
            if ok { onReady?(model) } else { onFailed?(model) }
        }
    }

    // MARK: - Found by the matrix

    private static func regressions(_ t: inout Checks) {
        typealias M = ModelResidencyTests
        // The continuous Parakeet's load failed; the other one sat on disk
        // unused and dictation had nothing.
        t.equal(ModelResidency.plan(M.picks(continuous: M.v2),
                                    M.states(downloaded: [M.turbo, M.ultra, M.v2], status: [M.v2: .failed("x")])),
                .standIn(M.ultra), "a failed stand-in passes to the next downloaded Parakeet")
        // The dictation pick's load failed; nothing re-planned, so the
        // continuous model waiting behind it never loaded.
        var failing = Scenario()
        failing.dictation = WhisperCatalog.base
        failing.dictationDisk = .failing
        failing.continuous = WhisperCatalog.turbo
        failing.continuousOn = true
        let run = Run(failing, tier: .relaxed)
        t.check(run.host.isReady(WhisperCatalog.turbo) && run.events.contains("failed \(WhisperCatalog.base)"),
                "a failed dictation load lets the continuous model load", run.events.joined(separator: ", "))
    }

    // MARK: - Failed downloads

    /// The dictation pick's download fails: the first failure changes
    /// nothing (Re-download is the retry), the second in a row re-plans so
    /// a downloaded Parakeet stands in — as a failed load does. Every pick
    /// that has a stand-in candidate, and every interruption of the streak.
    private static func failedDownloads(_ t: inout Checks) {
        let standIn = ModelCatalog.defaultContinuous
        let picks = ModelCatalog.ids(of: .whisper) + [fineTune]

        /// A launch with `pick` downloading (so no stand-in yet), nothing
        /// serving, and the Parakeet on disk; then `steps`. True when the
        /// Parakeet ended serving dictation.
        func standsIn(_ pick: String, _ steps: [Step]) -> Bool {
            let host = Host()
            let other = ModelCatalog.ids(of: .whisper).first { $0 != pick }!
            let s = Settings(store: InMemoryStore(), loginItemEnabled: { false })
            s.whisperModel = pick
            s.continuousModel = standIn
            s.streamHotkey = nil
            let residency = ModelResidency(whisper: host, settings: s, spawn: { _ in })
            host.onReady = { [weak residency] in residency?.modelReady($0) }
            host.place(standIn, .onDisk)
            host.place(pick, .downloading)
            residency.refresh()
            guard !host.events.contains("load \(standIn)") else { return true }   // the premise broke
            for step in steps {
                switch step {
                case .fail:
                    host.statuses[pick] = .failed("Download failed: offline")
                    residency.downloadFinished(pick, ok: false)
                case .succeed:
                    // Its files landed; the load that follows is still compiling.
                    host.statuses[pick] = .preparing("Loading")
                    residency.downloadFinished(pick, ok: true)
                    host.statuses[pick] = .downloading(0)   // Re-download deletes them again
                case .otherModelFails:
                    residency.downloadFinished(standIn, ok: false)
                case .pickAway:
                    host.place(other, .downloading)   // so it brings no stand-in of its own
                    s.whisperModel = other
                    residency.refresh()
                    s.whisperModel = pick
                    host.place(pick, .downloading)
                    residency.refresh()
                }
            }
            while !host.queue.isEmpty { host.finishNextLoad() }
            return residency.servingDictationModel == standIn && host.isReady(standIn)
        }

        let cases: [(steps: [Step], standsIn: Bool, name: String)] = [
            ([], false, "no failure: nothing stands in behind the running download"),
            ([.fail], false, "one failed download changes nothing"),
            ([.fail, .fail], true, "two failed downloads in a row: the Parakeet stands in"),
            ([.fail, .succeed, .fail], false, "a successful download resets the count"),
            ([.fail, .pickAway, .fail], false, "picking another model resets the count"),
            ([.fail, .otherModelFails], false, "another model's failed download doesn't count"),
            ([.fail, .otherModelFails, .fail], true, "…nor break the pick's streak"),
            ([.fail, .fail, .fail], true, "a third failure keeps the stand-in"),
        ]
        for c in cases {
            let wrong = picks.filter { standsIn($0, c.steps) != c.standsIn }
            t.check(wrong.isEmpty, "\(c.name) (\(picks.count) Whisper picks)", "wrong for \(wrong)")
        }
    }

    enum Step { case fail, succeed, otherModelFails, pickAway }

    // MARK: - Tiers and memory

    static let ramClasses = [8, 16, 24, 32]

    private static func tiersAndMemory(_ t: inout Checks) {
        t.check(SpeedTier.allCases.allSatisfy { tier in
            let p = ResidencyPolicy(tier)
            return p.pins == tier.pinsModels && p.releasesUnderPressure == tier.releasesUnderPressure
                && p.primesOnHold == tier.primesOnHold && p.warmsAfterLoad == tier.warmsAfterLoad
                && p.pins != p.releasesUnderPressure
        }, "every speed tier: its residency policy is its knobs, and a tier either pins or releases")

        // A Neural Engine compile that hangs must still end on a CPU copy,
        // well before the load's hard timeout, on every Mac and every model.
        let bases = ModelCatalog.ids(of: .whisper) + ["large-v3"]
        var late: [String] = []
        for ram in ramClasses {
            for model in bases {
                let delay = TranscriptionModel.cpuCopyDelay(model: model, physicalMemory: UInt64(ram) << 30)
                if !(delay >= TranscriptionModel.cpuCopyAfterSeconds && delay < Double(ModelLoads.timeoutSeconds) / 2) {
                    late.append("\(model)@\(ram)GB=\(delay)")
                }
            }
        }
        t.check(late.isEmpty, "every Whisper model × \(ramClasses.map { "\($0) GB" }.joined(separator: "/")): "
                    + "the CPU copy comes in well before the load times out", late.joined(separator: ", "))
        t.check(TranscriptionModel.cpuCopyDelay(model: WhisperCatalog.turbo, physicalMemory: 8 << 30)
                    > TranscriptionModel.cpuCopyDelay(model: WhisperCatalog.turbo, physicalMemory: 16 << 30),
                "an 8 GB Mac waits longer for a large model's Neural Engine copy")

        // The local server's memory slider (Full) on every RAM class, and an
        // unreadable one (0).
        var bad: [String] = []
        for ram in [0] + ramClasses + [64] {
            let def = Settings.localMemDefaultGB(ramGB: ram), max = Settings.localMemMaxGB(ramGB: ram)
            if !(def >= 2 && def <= max && (ram == 0 || max <= Double(ram - 2))) { bad.append("\(ram)GB: \(def)/\(max)") }
        }
        t.check(bad.isEmpty, "every RAM class: the local-model memory default sits inside its slider, "
                    + "leaving macOS 2 GB", bad.joined(separator: ", "))
    }
}
