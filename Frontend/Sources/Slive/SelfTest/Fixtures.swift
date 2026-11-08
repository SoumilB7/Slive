import AppKit
import CoreGraphics
import SliveTestKit

/// Shared hotkey fixtures used by more than one suite.
enum Fixtures {
    static let fn = CGEventFlags.maskSecondaryFn.rawValue
    static let ctrl = CGEventFlags.maskControl.rawValue
    static let cmd = CGEventFlags.maskCommand.rawValue
    static let alt = CGEventFlags.maskAlternate.rawValue

    @MainActor static func flagsEvent(_ flags: UInt64, marker: Bool = false) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        e.type = .flagsChanged
        e.flags = CGEventFlags(rawValue: flags)
        if marker { e.setIntegerValueField(.eventSourceUserData, value: SyntheticTyper.syntheticMarker) }
        return e
    }

    /// Fresh monitor with deterministic targets (never start()ed — no tap, no
    /// timers; we drive handle() directly, the same entry real events take).
    @MainActor static func makeMonitor(started: @escaping (HotkeyAction) -> Void,
                            stopped: @escaping (HotkeyAction) -> Void) -> HotkeyMonitor {
        let m = HotkeyMonitor()
        m.hotkey = Hotkey(modifiers: fn, keyCode: nil, label: "fn")
        m.assistantHotkey = nil
        m.streamHotkey = Hotkey(modifiers: ctrl, keyCode: nil, label: "⌃")
        m.onStart = { action, _ in started(action) }
        m.onStop = stopped
        return m
    }
}

/// One check for a whole swept dimension (thousands of configs): counts the
/// cases and lists the first failures instead of printing a line per case.
struct Sweep {
    private(set) var count = 0
    private(set) var failures: [String] = []

    mutating func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        count += 1
        guard !ok else { return }
        failures.append(failures.count < 8 ? what() : "")
    }

    func report(_ t: inout Checks, _ name: String) {
        let shown = failures.filter { !$0.isEmpty }.joined(separator: "; ")
        t.check(failures.isEmpty, "\(name) (\(count) cases)", "\(failures.count) failed: \(shown)")
    }
}
