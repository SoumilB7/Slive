import Foundation
import SliveTestKit

/// Shared machinery for the G1 world simulators (sim-live, sim-keys,
/// sim-recorder): seeded dice, per-run findings, the seed loop that folds
/// every seed into one check per invariant, and the shrinker that turns the
/// first failing seed into a short script anyone can read and replay.
enum SimKit {
    /// The seeded RNG with the few draws the generators need. Our own math
    /// (not `Int.random(in:using:)`) so a toolchain change can't reshuffle
    /// every saved seed.
    struct Dice {
        private var rng: SeededRandom
        init(seed: UInt64, salt: UInt64) { rng = SeededRandom(seed: seed &* 0x9E37_79B9 ^ salt) }

        mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(rng.next() % UInt64(n)) }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }

        /// One of `options`, by weight.
        mutating func weighted<T>(_ options: [(Int, T)]) -> T {
            var roll = below(options.reduce(0) { $0 + $1.0 })
            for (weight, value) in options {
                if roll < weight { return value }
                roll -= weight
            }
            return options[options.count - 1].1
        }
    }

    /// What one scripted run found: the ids it judged, and the first reason
    /// each failing id failed.
    struct Findings {
        private(set) var judged: Set<String> = []
        private(set) var failures: [String: String] = [:]

        /// Record a verdict for `id` (only the first failure's detail is kept).
        mutating func expect(_ ok: Bool, _ id: String, _ detail: @autoclosure () -> String) {
            judged.insert(id)
            if !ok, failures[id] == nil { failures[id] = detail() }
        }

        func failed(_ id: String) -> Bool { failures[id] != nil }
    }

    /// A family's invariant: its check id and what it promises.
    struct Invariant {
        let id: String
        let name: String
    }

    /// Run every seed of `run`, then record one check per invariant (how
    /// many seeds judged it, how many failed, the first failure). The first
    /// failing seed of each id is shrunk and saved as a regression.
    @MainActor
    static func runSeeds<Config, Event>(
        _ run: inout GauntletRun, family: String, salt: UInt64, invariants: [Invariant],
        generate: (inout Dice) -> (Config, [Event]),
        play: (Config, [Event]) -> Findings,
        script: (Config, [Event]) -> String
    ) {
        Log.routeEventsToSelfTest()   // fake sessions must not read as real ones in the events log
        var judged: [String: Int] = [:]
        var failing: [String: [UInt64]] = [:]
        var firstDetail: [String: String] = [:]
        var firstScript: [String: (Config, [Event])] = [:]
        for seed in run.seeds {
            var dice = Dice(seed: seed, salt: salt)
            let (config, events) = generate(&dice)
            let found = play(config, events)
            for id in found.judged { judged[id, default: 0] += 1 }
            for (id, detail) in found.failures {
                failing[id, default: []].append(seed)
                if firstDetail[id] == nil {
                    firstDetail[id] = "seed \(seed): \(detail)"
                    firstScript[id] = (config, events)
                }
            }
        }
        for inv in invariants {
            let bad = failing[inv.id] ?? []
            let count = judged[inv.id] ?? 0
            // A full run must reach every invariant; a one-seed replay needn't.
            let reached = count > 0 || run.seeds.count < 50
            run.check(bad.isEmpty && reached, id: inv.id, "\(inv.name) (\(count) of \(run.seeds.count) seeds)",
                      !reached ? "no seed exercised it" :
                        "\(bad.count) seeds failed (\(bad.prefix(8).map(String.init).joined(separator: ", "))); "
                        + (firstDetail[inv.id] ?? ""))
            guard let seed = bad.first, let first = firstScript[inv.id] else { continue }
            let config = first.0
            let small = shrink(first.1) { play(config, $0).failed(inv.id) }
            let why = play(config, small).failures[inv.id] ?? ""
            run.regression(family: family, seed: seed,
                           script: "    [\(inv.id)] \(why)\n" + script(config, small))
        }
    }

    /// Delta debugging: drop ever smaller chunks of `events` while the run
    /// still fails the same way. `budget` caps the replays so a known-red
    /// check can't blow the family's time.
    @MainActor
    static func shrink<Event>(_ events: [Event], budget: Int = 300,
                              keepsFailing: ([Event]) -> Bool) -> [Event] {
        var current = events
        var chunk = max(1, current.count / 2)
        var tries = 0
        while tries < budget {
            var removed = false
            var i = 0
            while i < current.count, tries < budget {
                var candidate = current
                candidate.removeSubrange(i..<min(i + chunk, current.count))
                tries += 1
                if keepsFailing(candidate) { current = candidate; removed = true } else { i += chunk }
            }
            if !removed {
                if chunk == 1 { break }
                chunk = max(1, chunk / 2)
            }
        }
        return current
    }

    /// "t=1.20" for a script line.
    static func stamp(_ t: TimeInterval) -> String { String(format: "t=%.2f", t) }

    // MARK: - One thread for async work

    /// Run `body` with every job bound for Swift's global executor sent to
    /// the main queue instead. A nonisolated `async` call (the typist's
    /// `finish`) otherwise runs on a pool thread at a moment the world can't
    /// see, so a run would depend on thread timing; on the main queue it
    /// runs in order, when the world drains it. Test-process only: it sets
    /// the concurrency runtime's enqueue hook and restores it after.
    @MainActor
    static func onMainQueue<T>(_ body: () -> T) -> T {
        guard let hook = enqueueGlobalHook else { return body() }
        let saved = hook.pointee
        hook.pointee = { job, _ in
            DispatchQueue.main.async { job.runSynchronously(on: MainActor.sharedUnownedExecutor) }
        }
        defer { hook.pointee = saved }
        return body()
    }

    private typealias Enqueue = @convention(thin) (UnownedJob) -> Void
    private typealias EnqueueHook = @convention(thin) (UnownedJob, Enqueue) -> Void
    /// `swift_task_enqueueGlobal_hook`: the concurrency runtime's hook for
    /// redirecting global jobs (what test-only serial executors use).
    nonisolated(unsafe) private static let enqueueGlobalHook: UnsafeMutablePointer<EnqueueHook?>? =
        dlsym(dlopen(nil, RTLD_NOW), "swift_task_enqueueGlobal_hook")?.assumingMemoryBound(to: EnqueueHook?.self)
}
