import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

private let fn = Fixtures.fn
private let ctrl = Fixtures.ctrl
private let cmd = Fixtures.cmd
private let alt = Fixtures.alt

@MainActor
enum HotkeyModelTests {
    static let suite = TestSuite(name: "Hotkey model") { t in
        print("[Hotkey model]")
        t.check(Hotkey.fnDefault.isModifierOnly && Hotkey.fnDefault.isValid, "fn default shape")
        t.check(!Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /").isModifierOnly, "chord shape")
        t.check(!Hotkey(modifiers: 0, keyCode: nil, label: "—").isValid, "empty hotkey invalid")

        t.equal(Hotkey.makeLabel(modifiers: 0, keyChar: nil), "—", "empty label")
        t.equal(Hotkey.makeLabel(modifiers: cmd, keyChar: nil), "⌘", "cmd label")
        t.equal(Hotkey.makeLabel(modifiers: ctrl | alt, keyChar: "K"), "⌃⌥ K", "chord label order")

        // Persistence round-trip: a change here breaks saved shortcuts.
        let original = Hotkey(modifiers: fn | ctrl, keyCode: 49, label: "⌃fn Space")
        if let data = try? JSONEncoder().encode(original),
           let back = try? JSONDecoder().decode(Hotkey.self, from: data) {
            t.equal(back, original, "hotkey codable round-trip")
        } else {
            t.check(false, "hotkey codable round-trip", "encode/decode threw")
        }

        t.check(Hotkey.isSpecialKey(53) && Hotkey.isSpecialKey(122) && Hotkey.isSpecialKey(123),
              "Esc/F1/← are special")
        t.check(!Hotkey.isSpecialKey(0) && !Hotkey.isSpecialKey(49), "'a'/Space are not special")
        t.equal(Hotkey.keyChar(forKeyCode: 49, characters: nil), "Space", "Space key name")
        t.equal(Hotkey.keyChar(forKeyCode: 0, characters: "a"), "A", "letter key name")
        t.equal(Hotkey.keyChar(forKeyCode: 200, characters: ""), "key200", "unknown key name")

        for flag: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn] {
            t.check(Hotkey.modifierMask & flag.rawValue != 0, "mask covers \(flag.rawValue)")
        }
        t.check(Hotkey.modifierMask & CGEventFlags.maskAlphaShift.rawValue == 0,
              "mask excludes caps lock")
    }
}
