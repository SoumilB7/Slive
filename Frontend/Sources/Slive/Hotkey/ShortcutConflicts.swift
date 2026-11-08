import Foundation

/// Two enabled shortcuts that get in each other's way. The verdict mirrors
/// what HotkeyMonitor + SessionCoordinator actually do (ShortcutConfigTests
/// runs every pair end to end, in every press order, against it), so the
/// recorder, the Settings rows and the tests all share one rule book.
struct ShortcutConflict: Equatable {
    enum Rule: CaseIterable {
        /// One gesture to the monitor, so only one of the two ever fires:
        /// a toggle beats a hold, then action priority decides. Two modifier
        /// toggles on the same keys (⌃ and ⌃ ×2) count as one gesture.
        case sameGesture
        /// A single-tap modifier toggle is pressed on the way into another
        /// shortcut, so using that shortcut starts a stray session.
        case tapInside
        /// A toggle whose keys include a modifier-only hold: the hold engages
        /// and ends the toggle's session. (Not the shared gesture a hold on X
        /// beside X ×2 makes: that pairing is meant to work.)
        case toggleThroughHold
    }

    let rule: Rule
    /// The other shortcut.
    let other: BindingSlot
    let otherHotkey: Hotkey
    /// Whether the checked shortcut is the one that stops working (false:
    /// the other one does).
    let breaksThis: Bool

    /// An exact clash: the recorder refuses it.
    var isExact: Bool { rule == .sameGesture }

    /// The Settings row's warning, naming the other shortcut.
    var message: String {
        let name = "\(other.displayName) (\(otherHotkey.displayLabel))"
        return isExact ? "Clashes with \(name)" : "Overlaps \(name)"
    }
}

enum ShortcutConflicts {
    /// Every conflict between `binding` and the rest of `bindings` (the
    /// effective list: pass `HotkeyBinding.effective`, so an action this
    /// build can't run never counts). Switched-off and unset shortcuts never
    /// conflict. Pure and cheap (Settings rows call it from `body`).
    static func check(_ binding: HotkeyBinding, against bindings: [HotkeyBinding]) -> [ShortcutConflict] {
        guard binding.enabled, let x = binding.hotkey, x.isValid else { return [] }
        var found: [ShortcutConflict] = []
        for other in bindings where other.slot != binding.slot && other.enabled {
            guard let y = other.hotkey, y.isValid else { continue }
            if let rule = breaks(x, binding.slot, by: y, other.slot) {
                found.append(ShortcutConflict(rule: rule, other: other.slot, otherHotkey: y, breaksThis: true))
            }
            if let rule = breaks(y, other.slot, by: x, binding.slot) {
                found.append(ShortcutConflict(rule: rule, other: other.slot, otherHotkey: y, breaksThis: false))
            }
        }
        return found
    }

    /// Why the recorder won't save `hotkey` on `slot`, if it won't: it is
    /// exactly another enabled shortcut's gesture. Nil = save it (soft
    /// overlaps are saved; the row warns).
    static func refusal(for hotkey: Hotkey, on slot: BindingSlot, among bindings: [HotkeyBinding]) -> String? {
        let mine = HotkeyBinding(action: slot.action, style: slot.style, hotkey: hotkey, enabled: true)
        return check(mine, against: bindings).first(where: \.isExact).map { "Used by \($0.other.displayName)" }
    }

    /// Why `x` (on `xs`) can't run cleanly while `y` (on `ys`) is bound, if
    /// it can't — in any order the user might press the modifiers.
    static func breaks(_ x: Hotkey, _ xs: BindingSlot, by y: Hotkey, _ ys: BindingSlot) -> ShortcutConflict.Rule? {
        if sameGesture(x, xs.style, y, ys.style) {
            switch (xs.style, ys.style) {
            case (.hold, .toggle): return .sameGesture        // the toggle is matched first
            case (.toggle, .hold): return nil
            default: return ys.action.priority < xs.action.priority ? .sameGesture : nil
            }
        }
        let pressed = physicalModifiers(x)
        // Pressing y's keys first (or x's modifiers before its key) passes
        // through y exactly. Equal modifier sets were settled above.
        let yInsideX = y.isModifierOnly && y.modifiers & pressed == y.modifiers
            && !(x.isModifierOnly && x.modifiers == y.modifiers)
        guard yInsideX else { return nil }
        if ys.style == .toggle && taps(y, ys.style) == 1 { return .tapInside }
        if xs.style == .toggle && ys.style == .hold { return .toggleThroughHold }
        return nil
    }

    /// The monitor's notion of one gesture: a chord's key + modifiers; a
    /// modifier set and tap count (holds have no taps; two modifier toggles
    /// on the same keys are matched by modifiers alone).
    static func sameGesture(_ x: Hotkey, _ xStyle: BindingStyle, _ y: Hotkey, _ yStyle: BindingStyle) -> Bool {
        guard x.modifiers == y.modifiers, x.keyCode == y.keyCode else { return false }
        if !x.isModifierOnly || (xStyle == .toggle && yStyle == .toggle) { return true }
        return taps(x, xStyle) == taps(y, yStyle)
    }

    /// Taps as the monitor counts them: only modifier-only toggles have ×2.
    static func taps(_ hk: Hotkey, _ style: BindingStyle) -> Int {
        style == .toggle && hk.isModifierOnly && hk.taps >= 2 ? 2 : 1
    }

    /// The modifiers a user physically holds for a shortcut (a key that
    /// carries fn implicitly is pressed without it).
    static func physicalModifiers(_ hk: Hotkey) -> UInt64 {
        guard let key = hk.keyCode, Hotkey.implicitFnKeyCodes.contains(key) else { return hk.modifiers }
        return hk.modifiers & ~Hotkey.fnFlag
    }
}

extension BindingSlot {
    /// How conflict copy names this shortcut: the action, plus hold/toggle
    /// when the action has both.
    var displayName: String {
        let spec = action.spec
        guard spec.hold != nil && spec.toggle != nil else { return spec.name }
        return "\(spec.name) \(style == .hold ? "hold" : "toggle")"
    }
}
