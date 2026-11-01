import AppKit
import CoreGraphics

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
        m.onStart = started
        m.onStop = stopped
        return m
    }
}
