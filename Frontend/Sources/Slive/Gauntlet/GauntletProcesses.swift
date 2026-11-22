import Foundation

// Processes the runner starts or must stop: the wall-clock limit (G9) and the
// children of `--burst`. Nothing here is on the simulated clock: real seconds
// are the point.

/// Reference box for state shared with reader threads.
final class GauntletLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// The run's wall-clock limit. A family that hangs blocks the main thread, so
/// the limit is enforced from another one: it names the family that was
/// running, stops any children and exits 1.
final class GauntletWatchdog: @unchecked Sendable {
    static let shared = GauntletWatchdog()

    private struct State {
        var family = "(before the first family)"
        var children: [Process] = []
    }
    private let state = GauntletLocked(State())

    func enter(family: String) { state.with { $0.family = family } }

    func track(_ child: Process) { state.with { $0.children.append(child) } }

    func untrack(_ child: Process) { state.with { $0.children.removeAll { $0 === child } } }

    func arm(seconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            let (family, children) = state.with { ($0.family, $0.children) }
            print("✗ time limit: more than \(seconds) s elapsed while running family '\(family)' (--max-seconds)")
            fflush(stdout)
            for child in children where child.isRunning { child.terminate() }
            exit(1)
        }
    }
}

/// Slive running itself as a child (`--gauntlet …`), output streamed by line.
enum GauntletChild {
    static var executable: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    struct Outcome {
        var status: Int32 = -1
        var lines: [String] = []
        var output: String { lines.joined(separator: "\n") }
    }

    /// Runs every argument set at once and waits for all. `onLine(index, line)`
    /// is called from the child's reader thread. A child still running after
    /// `timeout` seconds is terminated (status stays non-zero).
    static func runAll(_ argumentSets: [[String]], timeout: TimeInterval,
                       onLine: @escaping @Sendable (Int, String) -> Void) -> [Int32] {
        let statuses = GauntletLocked([Int32](repeating: -1, count: argumentSets.count))
        let group = DispatchGroup()
        var processes: [Process] = []
        for (index, arguments) in argumentSets.enumerated() {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch {
                onLine(index, "§G LAUNCH-FAILED \(error.localizedDescription)")
                continue
            }
            processes.append(process)
            GauntletWatchdog.shared.track(process)
            group.enter()
            let reader = pipe.fileHandleForReading
            Thread.detachNewThread {
                var pending = Data()
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        onLine(index, String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
                if !pending.isEmpty { onLine(index, String(decoding: pending, as: UTF8.self)) }
                process.waitUntilExit()
                statuses.with { $0[index] = process.terminationStatus }
                GauntletWatchdog.shared.untrack(process)
                group.leave()
            }
        }
        let started = processes
        let killer = DispatchWorkItem { for p in started where p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        group.wait()
        killer.cancel()
        return statuses.with { $0 }
    }

    /// One child, whole output.
    static func run(_ arguments: [String], timeout: TimeInterval = 60) -> Outcome {
        let lines = GauntletLocked([String]())
        let statuses = runAll([arguments], timeout: timeout) { _, line in lines.with { $0.append(line) } }
        return Outcome(status: statuses[0], lines: lines.with { $0 })
    }
}

/// What one family produced, whether it ran in this process or in a burst.
struct GauntletFamilyResult {
    var passed = 0
    var failed = 0
    var failedIDs: Set<String> = []
    var ranIDs: Set<String> = []
    /// Regression files written (paths), for the log.
    var savedRegressions: [String] = []
    /// ❌ lines, first-seen order, with how many seeds produced each.
    var failureLines: [(text: String, count: Int)] = []
    /// Why a burst child gave no answer.
    var infrastructure: [String] = []

    mutating func addFailureLine(_ text: String) {
        if let i = failureLines.firstIndex(where: { $0.text == text }) { failureLines[i].count += 1 }
        else { failureLines.append((text, 1)) }
    }
}

/// `--burst`: one family's seeds fanned over child processes, results merged.
/// Children run the normal runner (`--burst-child`) and report on `§G` lines;
/// the ✅ per-check noise from tens of thousands of seeds is dropped here.
enum GauntletBurst {
    static let protocolPrefix = "§G "

    static func run(family: String, seeds: [UInt64], options: GauntletOptions, fixtures: URL?,
                    remainingSeconds: TimeInterval) -> GauntletFamilyResult {
        let jobs = options.jobs ?? ProcessInfo.processInfo.activeProcessorCount
        let slices = GauntletSeeds.split(seeds, into: jobs)
        let seedText = slices.map { GauntletSeeds.format(GauntletSeeds.ranges($0)) }
        let argumentSets = seedText.map { seeds -> [String] in
            var args = ["--gauntlet", "--burst-child", "--only", family,
                        "--seed-range", seeds,
                        "--max-seconds", String(max(1, remainingSeconds))]
            switch options.suite {
            case .all: break
            case .demo: args.append("--demo")
            case .canary: args.append("--canary")
            case .stall: args.append("--demo-stall")
            }
            if let crash = options.demoCrashSeed { args += ["--demo-crash", String(crash)] }
            if let fixtures { args += ["--fixtures", fixtures.path] }
            return args
        }
        let results = GauntletLocked([GauntletFamilyResult](repeating: GauntletFamilyResult(), count: slices.count))
        let answered = GauntletLocked([Bool](repeating: false, count: slices.count))
        let tails = GauntletLocked([[String]](repeating: [], count: slices.count))
        let statuses = GauntletChild.runAll(argumentSets, timeout: remainingSeconds + 5) { index, line in
            if line.hasPrefix(protocolPrefix) {
                let words = line.dropFirst(protocolPrefix.count).split(separator: " ").map(String.init)
                results.with { r in
                    switch words.first {
                    case "RESULT" where words.count == 3:
                        r[index].passed = Int(words[1]) ?? 0
                        r[index].failed = Int(words[2]) ?? 0
                        answered.with { $0[index] = true }
                    case "RAN": r[index].ranIDs.formUnion(words.dropFirst())
                    case "FAILED": r[index].failedIDs.formUnion(words.dropFirst())
                    case "REG": r[index].savedRegressions.append(words.dropFirst().joined(separator: " "))
                    default: break
                    }
                }
            } else if line.hasPrefix("  ❌") {
                results.with { $0[index].addFailureLine(line) }
            } else if !line.hasPrefix("  ✅") {
                tails.with { t in t[index].append(line); if t[index].count > 12 { t[index].removeFirst() } }
            }
        }
        var merged = GauntletFamilyResult()
        for (index, r) in results.with({ $0 }).enumerated() {
            merged.passed += r.passed
            merged.failed += r.failed
            merged.failedIDs.formUnion(r.failedIDs)
            merged.ranIDs.formUnion(r.ranIDs)
            merged.savedRegressions += r.savedRegressions
            for (text, count) in r.failureLines { for _ in 0..<count { merged.addFailureLine(text) } }
            if !answered.with({ $0[index] }) {
                merged.failedIDs.insert("\(family).burst-child-died")
                merged.infrastructure.append("burst child \(index + 1)/\(slices.count) "
                    + "(seeds \(seedText[index])) exited \(statuses[index]) without a result; last output:\n"
                    + tails.with { $0[index] }.map { "      " + $0 }.joined(separator: "\n"))
            }
        }
        return merged
    }
}
