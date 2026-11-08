import CoreGraphics
import Foundation

/// A recorded push-to-talk shortcut. You hold the whole thing — all the
/// modifiers, plus the key if there is one — to talk.
///
/// Two shapes:
/// - **Modifier-only** (`keyCode == nil`): e.g. fn, Right ⌥, ⌃⌥. Detected with a
///   listen-only tap (Input Monitoring); nothing is ever suppressed.
/// - **Chord with a key** (`keyCode != nil`): e.g. ⌥ + /. Detected with a
///   consuming tap (Accessibility) so the key is swallowed while held instead of
///   typing into your app.
///
/// NSEvent's modifier flags and CGEventFlags share the same bit values, so the
/// recorder (NSEvent) and the monitor (CGEvent) speak the same numbers.
public struct Hotkey: Codable, Equatable, Sendable {
    /// Modifier bits that must be held, masked to the standard set below.
    public var modifiers: UInt64
    /// The main non-modifier key's virtual keycode, or nil for modifier-only.
    public var keyCode: UInt16?
    /// Readable label built when recorded, e.g. "⌥ /" or "fn ×2".
    public var label: String
    /// How many quick taps trigger this bind (toggle binds only): 1 = a
    /// single press, 2 = double-tap within `Hotkey.doubleTapInterval`. Lets
    /// one physical key carry two meanings (fn hold ≠ fn-fn) — the cure for
    /// running out of rememberable combos.
    public var taps: Int = 1

    /// Two down-edges of the same gesture within this window = a double-tap.
    public static let doubleTapInterval: TimeInterval = 0.45

    private enum CodingKeys: String, CodingKey { case modifiers, keyCode, label, taps }

    public init(modifiers: UInt64, keyCode: UInt16?, label: String, taps: Int = 1) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.label = label
        self.taps = taps
    }

    /// Tolerant decode: binds saved before `taps` existed load as single-tap.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modifiers = try c.decode(UInt64.self, forKey: .modifiers)
        keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode)
        label = try c.decode(String.self, forKey: .label)
        taps = try c.decodeIfPresent(Int.self, forKey: .taps) ?? 1
    }

    public static let modifierMask: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    public var isModifierOnly: Bool { keyCode == nil }
    public var isValid: Bool { modifiers != 0 || keyCode != nil }

    /// Default shortcut: hold fn (the Globe key).
    public static let fnDefault = Hotkey(
        modifiers: CGEventFlags.maskSecondaryFn.rawValue,
        keyCode: nil,
        label: "fn 🌐"
    )

    /// Build a readable label from a modifier set + an optional key character.
    public static func makeLabel(modifiers: UInt64, keyChar: String?) -> String {
        var symbols = ""
        if modifiers & CGEventFlags.maskControl.rawValue != 0 { symbols += "⌃" }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { symbols += "⌥" }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 { symbols += "⇧" }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { symbols += "⌘" }
        if modifiers & CGEventFlags.maskSecondaryFn.rawValue != 0 { symbols += "fn" }

        guard let keyChar, !keyChar.isEmpty else {
            return symbols.isEmpty ? "—" : symbols
        }
        return symbols.isEmpty ? keyChar : "\(symbols) \(keyChar)"
    }

    /// The fn flag on its own.
    public static let fnFlag: UInt64 = CGEventFlags.maskSecondaryFn.rawValue

    /// Keys that don't type text, so they're fine to use bare (no modifier):
    /// Esc, the function row, and the arrows.
    public static func isSpecialKey(_ code: UInt16) -> Bool {
        let special: Set<UInt16> = [
            53,                                                    // Esc
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
            123, 124, 125, 126,                                    // arrows
        ]
        return special.contains(code)
    }

    /// Keys macOS reports as fn+key though fn is never touched (F1–F20, the
    /// arrows, Home/End, Page Up/Down, Forward Delete, Help): their events —
    /// and so a shortcut recorded on one — carry the fn flag, but the fn KEY
    /// is up.
    public static let implicitFnKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,   // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90,                       // F13–F20
        123, 124, 125, 126,                                       // arrows
        115, 119, 116, 121, 117, 114,                             // Home End PgUp PgDn ⌦ Help
    ]

    /// Whether pressing the key (with ⇧ at most) types or edits text — so
    /// ⇧ + it as a shortcut would take that character away.
    public static func typesText(_ code: UInt16) -> Bool {
        !isSpecialKey(code) && !implicitFnKeyCodes.contains(code)
    }

    /// The fixed name of a key whose character is layout-independent or
    /// unprintable (the function keys' characters are private-use glyphs).
    public static func keyName(_ code: UInt16) -> String? {
        switch code {
        case 49:  return "Space"
        case 36:  return "Return"
        case 48:  return "Tab"
        case 51:  return "Delete"
        case 53:  return "Esc"
        case 76:  return "Enter"
        case 71:  return "Clear"
        case 122: return "F1";  case 120: return "F2";  case 99:  return "F3"
        case 118: return "F4";  case 96:  return "F5";  case 97:  return "F6"
        case 98:  return "F7";  case 100: return "F8";  case 101: return "F9"
        case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        case 105: return "F13"; case 107: return "F14"; case 113: return "F15"
        case 106: return "F16"; case 64:  return "F17"; case 79:  return "F18"
        case 80:  return "F19"; case 90:  return "F20"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        case 115: return "Home"; case 119: return "End"
        case 116: return "Page Up"; case 121: return "Page Down"
        case 117: return "⌦"; case 114: return "Help"
        default:  return nil
        }
    }

    /// Human-friendly name for a virtual keycode: its fixed name, else the
    /// given character.
    public static func keyChar(forKeyCode code: UInt16, characters: String?) -> String {
        if let name = keyName(code) { return name }
        let c = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? "key\(code)" : c.uppercased()
    }

    /// A chord's label as the user pressed it: the fn its key's events
    /// carry implicitly is not shown ("F5", not "fn F5").
    public static func makeLabel(modifiers: UInt64, keyCode: UInt16, characters: String?) -> String {
        let shown = implicitFnKeyCodes.contains(keyCode) ? modifiers & ~fnFlag : modifiers
        return makeLabel(modifiers: shown, keyChar: keyChar(forKeyCode: keyCode, characters: characters))
    }

    /// What Settings shows. Rebuilt from the key for named keys, so labels
    /// stored by older recorders ("fn F5", "fn →", private-use glyphs for
    /// Home/End) read as the key; others keep the recorded label (a letter's
    /// character depends on the layout it was recorded with).
    public var displayLabel: String {
        guard let keyCode, Self.keyName(keyCode) != nil else { return label }
        return Self.makeLabel(modifiers: modifiers, keyCode: keyCode, characters: nil)
    }
}
