import Foundation

// G9 harness integrity and G10 static guards: the Gauntlet checking itself.
//
// A runner that can't fail is worse than none, so these run the real runner
// as child processes on private families (`--demo`, `--canary`,
// `--demo-stall`) and assert that failures are reported, the ledger ratchets,
// regressions replay, bursts merge and the time limit holds.

/// Families that exist only to exercise the runner. Never listed in
/// `GauntletFamilies.all`; `--demo`, `--canary` and `--demo-stall` select them.
@MainActor enum GauntletPrivate {
    /// The seed the demo family fails on.
    static let unluckySeed: UInt64 = 7
    /// Set from `--demo-crash`.
    static var crashSeed: UInt64?

    /// One seeded check that fails for seed 7, with a regression script.
    static let demo = GauntletFamily(name: "demo", seeded: true) { run in
        for seed in run.seeds {
            if seed == crashSeed { exit(86) }
            run.check(seed != unluckySeed, id: "demo.seven", "demo seed \(seed) is not the unlucky one", "seed \(seed)")
            if seed == unluckySeed {
                run.regression(family: "demo", seed: seed,
                               script: "t=0.00 press dictate\nt=0.40 release\nt=0.41 seed \(seed) goes wrong")
            }
        }
    }

    /// One check that always fails: proves a failure is reported.
    static let canary = GauntletFamily(name: "canary", seeded: false) { run in
        run.check(false, id: "harness.canary", "canary always fails", "this failure is the point")
    }

    /// Blocks far longer than any limit a test sets: proves the time bound.
    static let stall = GauntletFamily(name: "stall", seeded: false) { _ in
        Thread.sleep(forTimeInterval: 60)
    }
}

@MainActor enum GauntletHarness {
    static let family = GauntletFamily(name: "harness", seeded: false) { run in
        options(&run)
        seedPlan(&run)
        ledger(&run)
        regressionStore(&run)
        guards(&run)
        runnerInChildren(&run)
    }

    // MARK: - In-process

    private static func options(_ run: inout GauntletRun) {
        let o = GauntletOptions(["--gauntlet", "--only", "x", "--seeds", "5", "--seed", "9", "--burst", "30", "--no-daily"])
        run.check(o.errors.isEmpty && o.only == "x" && o.explicitSeeds == [9] && o.burst == 30 && o.seedCount == 30 && !o.daily,
                  id: "harness.options-parse", "flags parse into options", "\(o)")
        let bad = [["--sedd"], ["--seed"], ["--seed", "abc"], ["--burst", "0"], ["--seed-range", "9:3"], ["--max-seconds"]]
        let rejected = bad.allSatisfy { !GauntletOptions(["--gauntlet"] + $0).errors.isEmpty }
        run.check(rejected, id: "harness.options-reject", "unknown flags and bad numbers are errors, not defaults")
    }

    private static func seedPlan(_ run: inout GauntletRun) {
        let monday = 1_795_000_000.0
        let o = GauntletOptions(["--gauntlet"])
        let plan = GauntletSeeds.plan(o, saved: [], epochSeconds: monday)
        let base = plan.filter { $0 <= 200 }
        let daily = plan.filter { $0 >= GauntletSeeds.dailyOrigin }
        run.check(plan.count == 250 && base == Array(1...200) && daily.count == 50,
                  id: "harness.seeds-default", "default seeds are 1…200 plus 50 date-derived", "\(plan.count) seeds")
        let sameDay = GauntletSeeds.daily(epochSeconds: monday + 3_600)
        let nextDay = GauntletSeeds.daily(epochSeconds: monday + 86_400)
        run.check(sameDay == daily && Set(nextDay).isDisjoint(with: daily) && nextDay.count == 50,
                  id: "harness.seeds-daily", "date-derived seeds are stable within a UTC day and fresh the next")
        let replay = GauntletSeeds.plan(GauntletOptions(["--gauntlet", "--seeds", "3", "--no-daily"]), saved: [7, 2], epochSeconds: monday)
        let single = GauntletSeeds.plan(GauntletOptions(["--gauntlet", "--seed", "7"]), saved: [2], epochSeconds: monday)
        run.check(replay == [1, 2, 3, 7] && single == [7],
                  id: "harness.seeds-replay", "saved seeds join a normal run; --seed replays exactly one", "\(replay) \(single)")
        let seeds: [UInt64] = [1, 2, 3, 7, 9, 10, 11, 50]
        let ranges = GauntletSeeds.ranges(seeds)
        let text = GauntletSeeds.format(ranges)
        let parts = GauntletSeeds.split(Array(1...10), into: 4)
        run.check(text == "1:3,7:7,9:11,50:50" && GauntletSeeds.parseRanges(text).map({ $0.flatMap { Array($0) } }) == seeds
                  && parts.flatMap { $0 } == Array(1...10) && parts.count == 4 && GauntletSeeds.split([], into: 3).isEmpty,
                  id: "harness.seeds-ranges", "seed ranges round-trip and a split covers every seed once", text)
    }

    private static func ledger(_ run: inout GauntletRun) {
        let good = GauntletLedger(parsing: "# header\n\nF12  # short custom words rewrite common words\nF3 # stuck\n")
        run.check(good.ids == ["F12", "F3"] && good.problems.isEmpty,
                  id: "harness.ledger-parse", "known-red lines parse: id, then a comment", "\(good.ids) \(good.problems)")
        let bad = GauntletLedger(parsing: "F1\nF2 #\nF3 x # two ids\nF4 # ok\nF4 # again\n")
        run.check(bad.problems.count == 4, id: "harness.ledger-malformed",
                  "uncommented, empty-comment, multi-id and duplicate lines are problems", bad.problems.joined(separator: " | "))
        let l = GauntletLedger(parsing: "A # a\nB # b\nC # c\n")
        let v = l.judge(failed: ["A", "N"], ran: ["A", "B", "N"])
        run.check(v.knownRed == ["A"] && v.new == ["N"] && v.fixed == ["B"] && v.notRun == ["C"] && !v.passes,
                  id: "harness.ledger-judge", "ledger: listed failure expected, unlisted new, passing listed id fixed, unrun id ignored", "\(v)")
        run.check(l.judge(failed: ["A", "B"], ran: ["A", "B", "C"]).fixed == ["C"]
                  && l.judge(failed: ["A", "B", "C"], ran: ["A", "B", "C"]).passes,
                  id: "harness.ledger-subset", "failures that are a subset of the ledger pass")
    }

    private static func regressionStore(_ run: inout GauntletRun) {
        let parsed = GauntletRegressionStore.parse(fileName: "sim-hold-8812.txt")
        run.check(parsed?.family == "sim-hold" && parsed?.seed == 8812
                  && GauntletRegressionStore.fileName(family: "sim-hold", seed: 8812) == "sim-hold-8812.txt"
                  && GauntletRegressionStore.parse(fileName: "notes.txt") == nil
                  && GauntletRegressionStore.parse(fileName: "-5.txt") == nil,
                  id: "harness.regression-names", "regression files are <family>-<seed>.txt, hyphenated families included")
        let dir = scratch("regress")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GauntletRegressionStore(directory: dir.appendingPathComponent("regressions"))
        store.save(family: "sim-hold", seed: 41, script: "t=0 press")
        store.save(family: "sim-hold", seed: 7, script: "t=0 press")
        store.save(family: "other", seed: 3, script: "x")
        let text = try? String(contentsOf: dir.appendingPathComponent("regressions/sim-hold-41.txt"), encoding: .utf8)
        run.check(store.savedSeeds(for: "sim-hold") == [7, 41] && store.savedSeeds(for: "none").isEmpty && text == "t=0 press\n",
                  id: "harness.regression-store", "saved scripts are listed per family and stored as their text")
    }

    // MARK: - G10: the guard script

    private static func guards(_ run: inout GauntletRun) {
        guard let frontend = GauntletRunner.frontendDirectory else {
            run.check(false, id: "harness.guards-found", "scripts/gauntlet-guards.sh is found from the working directory or the binary")
            return
        }
        let script = frontend.appendingPathComponent("scripts/gauntlet-guards.sh").path
        let tree = scratch("guards")
        defer { try? FileManager.default.removeItem(at: tree) }
        let modes = tree.appendingPathComponent("Sources/Slive/Modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modes, withIntermediateDirectories: true)
        let source = """
            func f() {
                // Date() in a comment is fine
                let s = "Task.sleep in a string"
                let t = Date()
                DispatchQueue.main.asyncAfter(when: .now() + 1) { }
                let k = try? SecItemCopyMatching(q, &out)
                let j = try? KeychainStore.get("a")
                Log.event("logged")
                while ready {
                    try? await Task.sleep(nanoseconds: 5)
                }
                let p1 = 1
                let p2 = 2
                let p3 = 3
                let p4 = 4
                let p5 = 5
                let p6 = 6
                while ok {
                    try? await Task.sleep(nanoseconds: 5)
                    if clock > maxWait { break }
                }
            }
            """
        try? source.write(to: modes.appendingPathComponent("X.swift"), atomically: true, encoding: .utf8)
        let found = shell(script, ["--root", tree.path])
        let expected = ["Sources/Slive/Modes/X.swift:4:", "Sources/Slive/Modes/X.swift:5:",
                        "Sources/Slive/Modes/X.swift:6: [try-keychain]", "Sources/Slive/Modes/X.swift:10: [sleep-loop]"]
        let missing = expected.filter { !found.output.contains($0) }
        let extra = ["X.swift:2:", "X.swift:3:", "X.swift:7:", "X.swift:8:", "X.swift:19: [sleep-loop]"]
            .filter { found.output.contains($0) }
        run.check(found.status == 1 && missing.isEmpty && extra.isEmpty,
                  id: "harness.guards-flag-violations",
                  "guards exit 1 with file:line for raw time, unlogged Keychain try? and an unbounded sleep loop",
                  "status \(found.status), missing \(missing), extra \(extra)\n\(found.output)")

        let allow = tree.appendingPathComponent("Fixtures/gauntlet", isDirectory: true)
        try? FileManager.default.createDirectory(at: allow, withIntermediateDirectories: true)
        let listed = shell(script, ["--root", tree.path, "--print-violations"]).output
        try? (listed + "\n").write(to: allow.appendingPathComponent("guard-allow.txt"), atomically: true, encoding: .utf8)
        let allowed = shell(script, ["--root", tree.path])
        try? (source + "\nlet again = Date()\n").write(to: modes.appendingPathComponent("X.swift"), atomically: true, encoding: .utf8)
        let grown = shell(script, ["--root", tree.path])
        run.check(allowed.status == 0 && grown.status == 1 && grown.output.contains("X.swift:23:"),
                  id: "harness.guards-allowlist", "allowlisted sites pass; one more site fails",
                  "listed \(allowed.status), grown \(grown.status)")

        let real = shell(script, ["--root", frontend.path])
        run.check(real.status == 0, id: "harness.guards-tree-clean", "the source tree passes the static guards", real.output)
        // F3: awaitServing polled for a model that could never arrive, with no
        // bound. The guard reads the loop's own text, so removing its deadline
        // brings the finding back as a `sleep-loop` violation in this file.
        let unbounded = real.output.split(separator: "\n").filter { $0.contains("Modes/ModeContext.swift") && $0.contains("[sleep-loop]") }
        run.check(unbounded.isEmpty, id: "F3", "awaitServing's wait loop carries a deadline (static guard)",
                  unbounded.joined(separator: "\n"))
    }

    // MARK: - G9: the runner, as child processes

    private struct Scenario {
        let name: String
        let arguments: [String]
        let dir: URL
    }

    private static func runnerInChildren(_ run: inout GauntletRun) {
        func scenario(_ name: String, _ arguments: [String], ledger: String? = "", files: [String: String] = [:],
                      suite: String? = "--demo") -> Scenario {
            let dir = scratch(name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let ledger { try? ledger.write(to: dir.appendingPathComponent("known-red.txt"), atomically: true, encoding: .utf8) }
            for (path, text) in files {
                let url = dir.appendingPathComponent(path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            return Scenario(name: name, arguments: ["--gauntlet"] + (suite.map { [$0] } ?? []) + ["--fixtures", dir.path] + arguments,
                            dir: dir)
        }
        let listed = "demo.seven  # seed 7 fails on purpose\n"
        let scenarios = [
            scenario("accept", ["--seed", "7"], ledger: listed),
            scenario("reject", ["--seed", "7"]),
            scenario("fixed", ["--seed", "3"], ledger: listed),
            scenario("replay", ["--seeds", "5", "--no-daily"], ledger: listed,
                     files: ["regressions/demo-7.txt": "t=0.00 press\n"]),
            scenario("no-replay", ["--seeds", "5", "--no-daily"], ledger: listed),
            scenario("burst", ["--burst", "40", "--no-daily", "--jobs", "4"], ledger: listed),
            scenario("burst-new", ["--burst", "40", "--no-daily", "--jobs", "4"]),
            scenario("burst-crash", ["--burst", "40", "--no-daily", "--jobs", "4", "--demo-crash", "7"]),
            scenario("canary", [], suite: "--canary"),
            scenario("zero", ["--only", "no-such-family"], suite: nil),
            scenario("stall", ["--max-seconds", "0.5"], suite: "--demo-stall"),
            scenario("flag", ["--sedd", "7"]),
            scenario("malformed", ["--seed", "7"], ledger: "demo.seven\n"),
        ]
        let outputs = GauntletLocked([[String]](repeating: [], count: scenarios.count))
        let statuses = GauntletChild.runAll(scenarios.map(\.arguments), timeout: 60) { index, line in
            outputs.with { $0[index].append(line) }
        }
        defer { for s in scenarios { try? FileManager.default.removeItem(at: s.dir) } }
        let text = outputs.with { $0.map { $0.joined(separator: "\n") } }
        func get(_ name: String) -> (status: Int32, out: String) {
            let i = scenarios.firstIndex { $0.name == name }!
            return (statuses[i], text[i])
        }
        func expect(_ id: String, _ what: String, _ name: String, status: Int32, contains: [String], absent: [String] = []) {
            let r = get(name)
            let missing = contains.filter { !r.out.contains($0) } + absent.filter { r.out.contains($0) }
            run.check(r.status == status && missing.isEmpty, id: id, what,
                      "exit \(r.status) (want \(status)), unexpected/missing \(missing)\n\(r.out.suffix(600))")
        }

        expect("harness.ledger-accepts-listed", "a failure listed in known-red.txt passes (exit 0)", "accept",
               status: 0, contains: ["0 passed, 1 failed", "1 known-red, 0 new, 0 fixed"])
        expect("harness.ledger-rejects-unlisted", "an unlisted failure fails the run (exit 1, 'new failure')", "reject",
               status: 1, contains: ["new failure: demo.seven", "0 known-red, 1 new"])
        expect("harness.ledger-flags-fixed", "a listed id that now passes fails the run until removed", "fixed",
               status: 1, contains: ["remove demo.seven from known-red.txt (fixed)", "0 known-red, 0 new, 1 fixed"])
        expect("harness.ledger-malformed-rejected", "a ledger line with no comment fails the run", "malformed",
               status: 1, contains: ["has no comment"])

        let written = try? String(contentsOf: scenarios[0].dir.appendingPathComponent("regressions/demo-7.txt"), encoding: .utf8)
        run.check(written == "t=0.00 press dictate\nt=0.40 release\nt=0.41 seed 7 goes wrong\n",
                  id: "harness.regression-written", "a failing seed's script is saved as regressions/<family>-<seed>.txt", "\(written ?? "nothing")")
        expect("harness.regression-replayed", "a saved regression seed is replayed though the base seeds don't reach it", "replay",
               status: 0, contains: ["replaying 1 saved (7)", "1 known-red, 0 new, 0 fixed"])
        expect("harness.regression-needs-file", "without the saved file the same run doesn't reach seed 7", "no-replay",
               status: 1, contains: ["remove demo.seven from known-red.txt (fixed)"])

        expect("harness.burst-merges", "--burst fans seeds over children and merges: 39 pass + 1 fail, the failure known-red", "burst",
               status: 0, contains: ["39 passed, 1 failed across 40 seeds", "39 passed, 1 failed · 1 known-red, 0 new"])
        expect("harness.burst-new-failure", "--burst reports a new failure from a child", "burst-new",
               status: 1, contains: ["new failure: demo.seven"])

        expect("harness.burst-child-death", "--burst fails (not silently passes) when a child dies without answering", "burst-crash",
               status: 1, contains: ["new failure: demo.burst-child-died", "exited 86 without a result"])

        expect("harness.canary-reported", "the canary family (always failing) is reported: exit 1, 'new failure'", "canary",
               status: 1, contains: ["new failure: harness.canary", "0 passed, 1 failed"])
        expect("harness.zero-checks-fail", "a run that checks nothing exits 1", "zero",
               status: 1, contains: ["No checks ran"])
        expect("harness.time-bound", "the wall-clock limit stops a hung family, names it, exits 1", "stall",
               status: 1, contains: ["time limit", "'stall'"])
        expect("harness.unknown-flag-rejected", "an unknown flag is an error, not a quiet default", "flag",
               status: 2, contains: ["unknown flag --sedd"])
    }

    // MARK: - Helpers

    private static func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slive-gauntlet-harness-\(name)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    private static func shell(_ script: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "couldn't start bash: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
