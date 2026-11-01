import Foundation
import os

/// Lightweight, runtime-gated diagnostic logging.
///
/// **Off by default** — end users see nothing. Turn it on in dev via the Settings
/// → General "Verbose logging" toggle, or by launching with `SLIVE_DEBUG=1`.
/// When off, the message closure isn't even evaluated (no cost).
///
/// Every line is prefixed `Slive.<category>:` so you can filter easily:
///   log stream --predicate 'eventMessage CONTAINS "Slive."' --style compact
///   log stream --predicate 'eventMessage CONTAINS "Slive.live"' --style compact
/// or search `Slive.` in Console.app.
enum Log {
    /// Master switch. Set once at launch (Settings + env) and updated live when
    /// the toggle changes. Reading a Bool from any thread is fine for a log gate.
    nonisolated(unsafe) static var enabled = false

    /// The `Slive.<category>:` prefix. Adding one = a case here + a one-line
    /// convenience below.
    enum Category: String, CaseIterable {
        case live, stt, hotkey, overlay, backend, app, training, paste
    }

    static func live(_ message: @autoclosure () -> String)    { emit(.live, message) }
    static func stt(_ message: @autoclosure () -> String)     { emit(.stt, message) }
    static func hotkey(_ message: @autoclosure () -> String)  { emit(.hotkey, message) }
    static func overlay(_ message: @autoclosure () -> String) { emit(.overlay, message) }
    static func backend(_ message: @autoclosure () -> String) { emit(.backend, message) }
    static func app(_ message: @autoclosure () -> String)     { emit(.app, message) }
    static func training(_ message: @autoclosure () -> String) { emit(.training, message) }
    static func paste(_ message: @autoclosure () -> String)   { emit(.paste, message) }

    /// Always-on dictation event line (captured / waiting / decoded / typed /
    /// dropped), PUBLIC in the unified log — NSLog'd strings show up as
    /// `<private>`, which made the Oct 7 "first dictation never typed" bug
    /// unreadable after the fact. Timings, models and states only — never
    /// transcript text. Read with:
    ///   /usr/bin/log show --last 1h --predicate 'subsystem == "com.slive.app"'
    static func event(_ message: String) {
        eventLogger.notice("\(message, privacy: .public)")
    }
    /// Where `event` lines go.
    nonisolated(unsafe) private(set) static var eventDestination = (subsystem: "com.slive.app", category: "events")
    nonisolated(unsafe) private static var eventLogger = Logger(subsystem: "com.slive.app", category: "events")

    /// `--self-test` only, before any suite runs: suites drive the real load
    /// and decode paths with fakes ("flaky: Neural Engine load failed…"), and
    /// those lines must not land in com.slive.app "events", which the problem
    /// reporter and the latency analysis read as real dictations (the latter
    /// by subsystem alone, hence a subsystem of their own). Set once,
    /// single-threaded.
    static func routeEventsToSelfTest() {
        eventDestination = (subsystem: "com.slive.app.selftest", category: "selftest")
        eventLogger = Logger(subsystem: eventDestination.subsystem, category: eventDestination.category)
    }

    private static func emit(_ category: Category, _ message: () -> String) {
        guard enabled else { return }
        NSLog("Slive.%@: %@", category.rawValue, message())
    }
}
