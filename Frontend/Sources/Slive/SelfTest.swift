import SliveCoreSuites
import SliveTestKit

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
/// Layout: the SliveTestKit target (Checks, TestSuite, the runner), the
/// SliveCoreSuites target (suites over SliveCore + SliveReport only, also run
/// alone by the `SliveSelfTest` executable), and here `SelfTest/Suites/` (one
/// file per app-bound suite) with `SelfTest/AllSuites.swift` (their registry).
@MainActor
enum SelfTest {
    static func runAndExit() -> Never {
        // Suites drive real load/decode paths with fakes; keep their event
        // lines out of the "events" log the reporter and latency reads use.
        Log.routeEventsToSelfTest()
        SelfTestRunner.runAndExit(CoreSuites.all + AllSuites.all)
    }
}
