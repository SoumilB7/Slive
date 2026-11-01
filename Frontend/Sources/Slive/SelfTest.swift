/// Built-in check suite, run with `Slive --self-test` (or
/// `swift run Slive --self-test`). Prints one line per check and exits 0 only
/// if everything passed. `--only <name>` runs just the suites whose name
/// contains it.
///
/// Why not XCTest / Swift Testing: this machine builds with the Command Line
/// Tools toolchain, which ships neither. Running assertions inside the real
/// module keeps the exact production code paths under test with zero extra
/// dependencies. Everything here is pure logic — no event posting, no AX, no
/// audio, no files outside the process — so the suite is safe to run headless.
///
/// Layout: `SelfTest/SelfTestKit.swift` (framework), `SelfTest/Suites/` (one
/// file per suite), `SelfTest/AllSuites.swift` (the registry).
@MainActor
enum SelfTest {
    static func runAndExit() -> Never {
        SelfTestRunner.runAndExit(AllSuites.all)
    }
}
