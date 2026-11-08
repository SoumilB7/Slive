import CoreGraphics
import Foundation
import SliveCore
import SliveTestKit

private let fn = CGEventFlags.maskSecondaryFn.rawValue
private let ctrl = CGEventFlags.maskControl.rawValue
private let cmd = CGEventFlags.maskCommand.rawValue
private let alt = CGEventFlags.maskAlternate.rawValue

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
        t.equal(Hotkey.keyChar(forKeyCode: 115, characters: "\u{F729}"), "Home", "Home reads as Home, not its glyph")
        t.equal(Hotkey.makeLabel(modifiers: fn, keyCode: 96, characters: nil), "F5", "F5 drops its implicit fn")
        t.equal(Hotkey.makeLabel(modifiers: ctrl | fn, keyCode: 124, characters: nil), "⌃ →", "⌃ → drops its implicit fn")
        t.equal(Hotkey.makeLabel(modifiers: fn, keyCode: 44, characters: "/"), "fn /", "a real fn chord keeps fn")
        t.equal(Hotkey(modifiers: fn, keyCode: 117, label: "fn \u{F728}").displayLabel, "⌦", "stored ⌦ glyph displays as ⌦")
        t.check(Hotkey.typesText(0) && Hotkey.typesText(49) && !Hotkey.typesText(96) && !Hotkey.typesText(115),
                "letters and Space type text; F5 and Home don't")
        t.check(Hotkey.implicitFnKeyCodes.allSatisfy { Hotkey.keyName($0) != nil },
                "every key that carries fn implicitly has a name")

        for flag: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn] {
            t.check(Hotkey.modifierMask & flag.rawValue != 0, "mask covers \(flag.rawValue)")
        }
        t.check(Hotkey.modifierMask & CGEventFlags.maskAlphaShift.rawValue == 0,
              "mask excludes caps lock")
    }
}
