import Foundation

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

    static func live(_ message: @autoclosure () -> String)    { emit("live", message) }
    static func stt(_ message: @autoclosure () -> String)     { emit("stt", message) }
    static func hotkey(_ message: @autoclosure () -> String)  { emit("hotkey", message) }
    static func overlay(_ message: @autoclosure () -> String) { emit("overlay", message) }
    static func backend(_ message: @autoclosure () -> String) { emit("backend", message) }
    static func app(_ message: @autoclosure () -> String)     { emit("app", message) }
    static func training(_ message: @autoclosure () -> String) { emit("training", message) }
    static func paste(_ message: @autoclosure () -> String)   { emit("paste", message) }

    private static func emit(_ category: String, _ message: () -> String) {
        guard enabled else { return }
        NSLog("Slive.%@: %@", category, message())
    }
}
