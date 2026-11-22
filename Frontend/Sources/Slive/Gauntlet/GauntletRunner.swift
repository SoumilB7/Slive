import Foundation
import SliveTestKit

/// `Slive --gauntlet`: runs every family, then judges the failures against the
/// known-red ledger. Flags are listed in `GauntletOptions.usage`.
///
/// Exit 0 only when at least one check ran, every failed id is in
/// Fixtures/gauntlet/known-red.txt, and no listed id has started passing.
/// Failing seeds are saved under Fixtures/gauntlet/regressions/ and replayed
/// on every later run of their family.
@MainActor enum GauntletRunner {
    /// Folders of this run, for families that read repo files.
    private(set) static var frontendDirectory: URL?
    private(set) static var fixturesDirectory: URL?

    static func runAndExit() -> Never {
        var options = GauntletOptions(Array(CommandLine.arguments.dropFirst()))
        guard options.errors.isEmpty else {
            print(options.errors.map { "✗ \($0)" }.joined(separator: "\n") + "\n" + GauntletOptions.usage)
            exit(2)
        }
        let started = Date()
        GauntletWatchdog.shared.arm(seconds: options.maxSeconds)

        // The runner's private suites never touch the repo's fixtures.
        var scratch: URL?
        if options.suite != .all, options.fixtures == nil {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("slive-gauntlet-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            options.fixtures = dir.path
            scratch = dir
        }
        frontendDirectory = GauntletPaths.frontend()
        fixturesDirectory = GauntletPaths.fixtures(option: options.fixtures, frontend: frontendDirectory)
        let store = fixturesDirectory.map { GauntletRegressionStore(directory: $0.appendingPathComponent("regressions")) }
        let isChild = options.isBurstChild
        GauntletPrivate.crashSeed = options.demoCrashSeed

        if !isChild { print("Slive Gauntlet\n==============") }
        var tally = GauntletFamilyResult()
        for family in selectedFamilies(options) {
            GauntletWatchdog.shared.enter(family: family.name)
            let saved = store?.savedSeeds(for: family.name) ?? []
            let seeds = family.seeded
                ? GauntletSeeds.plan(options, saved: saved, epochSeconds: Date().timeIntervalSince1970) : []
            if !isChild { print("[\(family.name)]" + describe(seeds, options: options, saved: saved, seeded: family.seeded)) }

            var result: GauntletFamilyResult
            if options.burst != nil, family.seeded, !seeds.isEmpty, !isChild {
                let remaining = options.maxSeconds - Date().timeIntervalSince(started)
                result = GauntletBurst.run(family: family.name, seeds: seeds, options: options,
                                           fixtures: fixturesDirectory, remainingSeconds: remaining)
                for (text, count) in result.failureLines.prefix(20) {
                    print(count > 1 ? "\(text)  (×\(count) seeds)" : text)
                }
                for note in result.infrastructure { print("  ✗ \(note)") }
                print("  \(result.passed) passed, \(result.failed) failed across \(seeds.count) seeds")
            } else {
                result = runInProcess(family, seeds: seeds, store: store, quiet: isChild)
            }
            for path in result.savedRegressions where !isChild { print("  ↺ regression file: \(display(path))") }
            tally.passed += result.passed
            tally.failed += result.failed
            tally.failedIDs.formUnion(result.failedIDs)
            tally.ranIDs.formUnion(result.ranIDs)
            tally.savedRegressions += result.savedRegressions
        }

        if isChild {
            print("§G RESULT \(tally.passed) \(tally.failed)")
            print("§G RAN " + tally.ranIDs.sorted().joined(separator: " "))
            print("§G FAILED " + tally.failedIDs.sorted().joined(separator: " "))
            for path in tally.savedRegressions { print("§G REG \(path)") }
            exit(0)
        }

        let ledger = loadLedger()
        let verdict = ledger.judge(failed: tally.failedIDs, ran: tally.ranIDs)
        print("==============")
        for problem in ledger.problems { print("✗ ledger: \(problem)") }
        if !verdict.knownRed.isEmpty { print("known-red (expected): " + verdict.knownRed.joined(separator: ", ")) }
        for id in verdict.new { print("✗ new failure: \(id) (not in known-red.txt)") }
        for id in verdict.fixed { print("✗ remove \(id) from known-red.txt (fixed)") }
        if !verdict.notRun.isEmpty, options.only == nil, options.suite == .all {
            print("note: known-red ids that did not run: " + verdict.notRun.joined(separator: ", "))
        }
        print("\(tally.passed) passed, \(tally.failed) failed · \(verdict.knownRed.count) known-red, "
              + "\(verdict.new.count) new, \(verdict.fixed.count) fixed · "
              + String(format: "%.1f s", Date().timeIntervalSince(started)))
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        if tally.passed + tally.failed == 0 {
            print("No checks ran. Check the --only filter.")
            exit(1)
        }
        exit(verdict.passes && ledger.problems.isEmpty ? 0 : 1)
    }

    // MARK: - Pieces

    private static func selectedFamilies(_ options: GauntletOptions) -> [GauntletFamily] {
        let all: [GauntletFamily]
        switch options.suite {
        case .all: all = GauntletFamilies.all
        case .demo: all = [GauntletPrivate.demo]
        case .canary: all = [GauntletPrivate.canary]
        case .stall: all = [GauntletPrivate.stall]
        }
        return all.filter { options.only == nil || $0.name == options.only }
    }

    private static func runInProcess(_ family: GauntletFamily, seeds: [UInt64],
                                     store: GauntletRegressionStore?, quiet: Bool) -> GauntletFamilyResult {
        var run = GauntletRun(seeds: seeds)
        family.run(&run)
        var result = GauntletFamilyResult(passed: run.checks.passed, failed: run.checks.failed,
                                          failedIDs: Set(run.failedIDs), ranIDs: run.ranIDs)
        if run.checks.failed > run.failedIDs.count {
            // Recorded straight into `run.checks`: no id, so the ledger can't match it.
            result.failedIDs.insert("\(family.name).unidentified")
            if !quiet { print("  ✗ \(family.name): checks failed without an id (use run.check(_:id:…))") }
        }
        for r in run.regressions {
            let url = store?.save(family: r.family, seed: r.seed, script: r.script)
            if let url { result.savedRegressions.append(url.path) }
            else if !quiet { print("  ✗ regression for \(r.family) seed \(r.seed) not saved (no Fixtures/gauntlet found)") }
            if !quiet { print("  ↺ \(r.family) seed \(r.seed):\n\(r.script)") }
        }
        return result
    }

    private static func describe(_ seeds: [UInt64], options: GauntletOptions, saved: [UInt64], seeded: Bool) -> String {
        guard seeded else { return "" }
        if options.explicitSeeds != nil { return " seeds \(GauntletSeeds.format(GauntletSeeds.ranges(seeds)))" }
        var parts = ["\(seeds.count) seeds: 1…\(options.seedCount)"]
        if options.daily, let first = GauntletSeeds.daily(epochSeconds: Date().timeIntervalSince1970).first {
            parts.append("daily \(first)…\(first + UInt64(GauntletSeeds.dailyCount) - 1)")
        }
        if !saved.isEmpty { parts.append("replaying \(saved.count) saved (\(saved.prefix(5).map(String.init).joined(separator: ", "))\(saved.count > 5 ? ", …" : ""))") }
        return " " + parts.joined(separator: " · ")
    }

    private static func loadLedger() -> GauntletLedger {
        guard let dir = fixturesDirectory else {
            print("note: no Fixtures/gauntlet found; known-red ledger is empty")
            return GauntletLedger()
        }
        let url = dir.appendingPathComponent("known-red.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return GauntletLedger() }
        return GauntletLedger(parsing: text)
    }

    private static func display(_ path: String) -> String {
        guard let base = fixturesDirectory?.deletingLastPathComponent().deletingLastPathComponent().path,
              path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }
}

/// Where the Frontend folder and its fixtures are, found from the working
/// directory or from the binary (`.build/release/Slive`).
enum GauntletPaths {
    static func frontend() -> URL? {
        var starts = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        starts.append(GauntletChild.executable.deletingLastPathComponent())
        for start in starts {
            var dir = start.standardizedFileURL
            for _ in 0..<6 {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/gauntlet-guards.sh").path) { return dir }
                dir = dir.deletingLastPathComponent()
            }
        }
        return nil
    }

    /// `--fixtures` (created if absent), `$SLIVE_GAUNTLET_FIXTURES`, else the Frontend's own.
    static func fixtures(option: String?, frontend: URL?) -> URL? {
        if let option {
            let url = URL(fileURLWithPath: option, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        if let env = ProcessInfo.processInfo.environment["SLIVE_GAUNTLET_FIXTURES"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        guard let url = frontend?.appendingPathComponent("Fixtures/gauntlet", isDirectory: true),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
