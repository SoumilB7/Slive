import AppKit
import CoreGraphics

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
struct Hotkey: Codable, Equatable {
    /// Modifier bits that must be held, masked to the standard set below.
    var modifiers: UInt64
    /// The main non-modifier key's virtual keycode, or nil for modifier-only.
    var keyCode: UInt16?
    /// Readable label built when recorded, e.g. "⌥ /" or "fn".
    var label: String

    static let modifierMask: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    var isModifierOnly: Bool { keyCode == nil }
    var isValid: Bool { modifiers != 0 || keyCode != nil }

    /// Default shortcut: hold fn (the Globe key).
    static let fnDefault = Hotkey(
        modifiers: CGEventFlags.maskSecondaryFn.rawValue,
        keyCode: nil,
        label: "fn 🌐"
    )

    /// Build a readable label from a modifier set + an optional key character.
    static func makeLabel(modifiers: UInt64, keyChar: String?) -> String {
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

    /// Keys that don't type text, so they're fine to use bare (no modifier):
    /// Esc, the function row, and the arrows.
    static func isSpecialKey(_ code: UInt16) -> Bool {
        let special: Set<UInt16> = [
            53,                                                    // Esc
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
            123, 124, 125, 126,                                    // arrows
        ]
        return special.contains(code)
    }

    /// Human-friendly name for a virtual keycode's non-typographic keys; falls
    /// back to the given character.
    static func keyChar(forKeyCode code: UInt16, characters: String?) -> String {
        switch code {
        case 49:  return "Space"
        case 36:  return "Return"
        case 48:  return "Tab"
        case 51:  return "Delete"
        case 53:  return "Esc"
        case 122: return "F1";  case 120: return "F2";  case 99:  return "F3"
        case 118: return "F4";  case 96:  return "F5";  case 97:  return "F6"
        case 98:  return "F7";  case 100: return "F8";  case 101: return "F9"
        case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        default:
            let c = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return c.isEmpty ? "key\(code)" : c.uppercased()
        }
    }
}
