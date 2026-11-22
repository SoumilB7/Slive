import AppKit
import CoreGraphics
import SliveTestKit

/// Every shortcut a user can record, on every slot, alone and in pairs —
/// driven through the real HotkeyMonitor (never armed: no tap) by a scripted
/// keyboard, and end to end through the SessionCoordinator. Slots come from
/// `ActionSpec.all` and recordable shortcuts from the recorder's own rules,
/// so a new action, slot or key is covered without touching this file.
@MainActor
enum ShortcutConfigTests {
    static let fn = CGEventFlags.maskSecondaryFn.rawValue
    static let ctrl = CGEventFlags.maskControl.rawValue
    static let alt = CGEventFlags.maskAlternate.rawValue
    static let shift = CGEventFlags.maskShift.rawValue
    static let cmd = CGEventFlags.maskCommand.rawValue
    /// Press order for a combo (released in reverse).
    static let modifierOrder: [UInt64] = [ctrl, alt, shift, cmd, fn]

    /// Every subset of the five modifiers (index 0 = none).
    static let modifierSets: [UInt64] = (0..<32).map { bits in
        modifierOrder.enumerated().reduce(UInt64(0)) { acc, e in bits & (1 << e.offset) != 0 ? acc | e.element : acc }
    }

    /// One modifier key: its keycode and the device-dependent flag bit its
    /// events carry (masked off by the monitor — left and right must match
    /// the same shortcut).
    struct ModKey { let code: CGKeyCode; let deviceBit: UInt64 }
    static let leftKeys: [UInt64: ModKey] = [
        ctrl: ModKey(code: 59, deviceBit: 0x1), alt: ModKey(code: 58, deviceBit: 0x20),
        shift: ModKey(code: 56, deviceBit: 0x2), cmd: ModKey(code: 55, deviceBit: 0x8),
        fn: ModKey(code: 63, deviceBit: 0),
    ]
    static let rightKeys: [UInt64: ModKey] = [
        ctrl: ModKey(code: 62, deviceBit: 0x2000), alt: ModKey(code: 61, deviceBit: 0x40),
        shift: ModKey(code: 60, deviceBit: 0x4), cmd: ModKey(code: 54, deviceBit: 0x10),
        fn: ModKey(code: 63, deviceBit: 0),
    ]
    /// Keycodes that only ever arrive as flagsChanged (modifiers, caps lock).
    static let modifierKeycodes: Set<UInt16> = Set(54...63)

    static func implicitFn(_ key: UInt16) -> Bool { HotkeyMonitor.implicitFnKeyCodes.contains(key) }

    /// The modifiers a user physically holds for a recorded shortcut (a key
    /// that carries fn implicitly was recorded with fn, pressed without it).
    static func physicalModifiers(_ hk: Hotkey) -> UInt64 {
        guard let key = hk.keyCode, implicitFn(key) else { return hk.modifiers }
        return hk.modifiers & ~fn
    }

    // MARK: - The scripted keyboard

    /// What the monitor said, per event.
    @MainActor final class Trail {
        var log: [String] = []
        var firesThisEvent = 0
        var maxFiresPerEvent = 0
    }

    /// A keyboard + manual clock in front of a never-armed HotkeyMonitor.
    @MainActor final class KeyRig {
        final class Keys { var down: Set<CGKeyCode> = [] }
        let clock: ManualScheduler
        let keys = Keys()
        let monitor: HotkeyMonitor
        let trail = Trail()
        var right = false
        var capsLock = false
        /// The end-to-end coordinator, kept alive as long as the rig.
        var retained: AnyObject?
        /// A modifier flagsChanged event was swallowed (must never happen).
        var swallowedModifier = false
        private let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!

        init(_ bindings: [HotkeyBinding], clock: ManualScheduler? = nil,
             session: SessionCoordinator? = nil) {
            let clock = clock ?? ManualScheduler()
            self.clock = clock
            let keys = self.keys
            monitor = HotkeyMonitor(armsTap: false, now: { clock.now },
                                    keyProbe: { keys.down.contains($0) })
            let trail = self.trail
            monitor.onStart = { [weak session] a, firstTapOf in
                trail.log.append("start \(a)"); trail.firesThisEvent += 1
                session?.keyDown(a, firstTapOf: firstTapOf)
            }
            monitor.onStop = { [weak session] a in trail.log.append("stop \(a)"); session?.keyUp() }
            monitor.onToggle = { [weak session] a in
                trail.log.append("toggle \(a)"); trail.firesThisEvent += 1; session?.toggleTapped(a)
            }
            monitor.bindings = bindings
        }

        private var modKeys: [UInt64: ModKey] { right ? ShortcutConfigTests.rightKeys : ShortcutConfigTests.leftKeys }

        /// Flags as the OS reports them: device-independent bits for every
        /// modifier physically down, plus their device bits and noise bits.
        var flags: UInt64 {
            var f: UInt64 = 0x100   // NX_NONCOALESCED, always set on real events
            for bit in ShortcutConfigTests.modifierOrder {
                for k in [ShortcutConfigTests.leftKeys[bit]!, ShortcutConfigTests.rightKeys[bit]!]
                where keys.down.contains(k.code) {
                    f |= bit | k.deviceBit
                }
            }
            if capsLock { f |= CGEventFlags.maskAlphaShift.rawValue }
            return f
        }

        @discardableResult
        func send(_ type: CGEventType, key: UInt16, flags: UInt64, autorepeat: Bool = false) -> Bool {
            event.type = type
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(key))
            event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
            event.flags = CGEventFlags(rawValue: flags)
            trail.firesThisEvent = 0
            let swallowed = monitor.handle(type: type, event: event)
            trail.maxFiresPerEvent = max(trail.maxFiresPerEvent, trail.firesThisEvent)
            if type == .flagsChanged && swallowed { swallowedModifier = true }
            return swallowed
        }

        /// Press modifiers last-first (and so release them first-first).
        var reversedOrder = false
        private var pressOrder: [UInt64] {
            reversedOrder ? ShortcutConfigTests.modifierOrder.reversed() : ShortcutConfigTests.modifierOrder
        }

        func pressModifiers(_ mods: UInt64, step: TimeInterval = 0.03) {
            for bit in pressOrder where mods & bit != 0 {
                keys.down.insert(modKeys[bit]!.code)
                send(.flagsChanged, key: UInt16(modKeys[bit]!.code), flags: flags)
                clock.advance(by: step)
            }
        }

        func releaseModifiers(_ mods: UInt64, step: TimeInterval = 0.03) {
            for bit in pressOrder.reversed() where mods & bit != 0 {
                keys.down.remove(modKeys[bit]!.code)
                send(.flagsChanged, key: UInt16(modKeys[bit]!.code), flags: flags)
                clock.advance(by: step)
            }
        }

        /// A key press with whatever is held; true = swallowed.
        func keyDown(_ key: UInt16, autorepeat: Bool = false) -> Bool {
            keys.down.insert(CGKeyCode(key))
            var f = flags
            if ShortcutConfigTests.implicitFn(key) { f |= ShortcutConfigTests.fn }
            if (123...126).contains(key) { f |= CGEventFlags.maskNumericPad.rawValue }
            return send(.keyDown, key: key, flags: f, autorepeat: autorepeat)
        }

        func keyUp(_ key: UInt16) -> Bool {
            keys.down.remove(CGKeyCode(key))
            var f = flags
            if ShortcutConfigTests.implicitFn(key) { f |= ShortcutConfigTests.fn }
            return send(.keyUp, key: key, flags: f)
        }

        /// Press a shortcut and keep holding it. Returns whether its key
        /// (if any) was swallowed. Earlier taps of a ×2 are completed first.
        @discardableResult
        func press(_ hk: Hotkey) -> Bool {
            let mods = ShortcutConfigTests.physicalModifiers(hk)
            for _ in 1..<max(1, hk.taps) {
                pressModifiers(mods); releaseModifiers(mods); clock.advance(by: 0.05)
            }
            pressModifiers(mods)
            guard let key = hk.keyCode else { return false }
            let swallowed = keyDown(key)
            clock.advance(by: 0.03)
            return swallowed
        }

        /// Let go of a held shortcut. Returns whether its key-up was swallowed.
        @discardableResult
        func release(_ hk: Hotkey) -> Bool {
            var swallowed = false
            if let key = hk.keyCode { swallowed = keyUp(key); clock.advance(by: 0.03) }
            releaseModifiers(ShortcutConfigTests.physicalModifiers(hk))
            return swallowed
        }

        func tap(_ hk: Hotkey) { press(hk); release(hk) }
    }

    static func binding(_ slot: BindingSlot, _ hk: Hotkey?, enabled: Bool = true) -> HotkeyBinding {
        HotkeyBinding(action: slot.action, style: slot.style, hotkey: hk, enabled: enabled)
    }

    static var allSlots: [BindingSlot] { ActionSpec.all.flatMap(\.slots) }

    // MARK: - Recordable shortcuts

    /// Every shortcut the recorder can produce on a key press: each keycode
    /// with each set of physically held modifiers (the event adds fn for
    /// keys that carry it).
    /// `refused`: ⇧ + a typing key. `blocked`: every other refusal, as
    /// "key<code>: <reason>" (a bare editing key, a system shortcut).
    static func recordedChords() -> (chords: [Hotkey], cancels: Int, ignored: Int, refused: Int,
                                     blocked: Set<String>, mismatches: [String]) {
        var chords: [Hotkey] = []
        var cancels = 0, ignored = 0, refused = 0
        var blocked: Set<String> = []
        var mismatches: [String] = []
        for key in UInt16(0)...127 where !modifierKeycodes.contains(key) {
            for physical in modifierSets {
                let mods = physical | (implicitFn(key) ? fn : 0)
                // Named keys arrive with a private-use glyph as their character.
                let chars: String? = Hotkey.keyName(key) != nil ? "\u{F729}" : nil
                let shiftedText = mods == shift && Hotkey.typesText(key)
                switch HotkeyRecorderView.keyDownOutcome(keyCode: key, modifiers: mods, characters: chars) {
                case .cancel:
                    cancels += 1
                    if key != 53 { mismatches.append("key\(key) cancels") }
                case .ignore:
                    ignored += 1
                    if mods != 0 || Hotkey.isSpecialKey(key) { mismatches.append("key\(key)/\(mods) ignored") }
                case .refuse(let why) where why == HotkeyRecorderView.shiftTypesText:
                    refused += 1
                    if !shiftedText { mismatches.append("key\(key)/\(mods) refused: \(why)") }
                case .refuse(let why):
                    blocked.insert("key\(key): \(why)")
                case .commit(let hk):
                    // The label reads as the key pressed: no implicit fn, no glyphs.
                    let shown = implicitFn(key) ? physical & ~fn : physical
                    let want = Hotkey.makeLabel(modifiers: shown,
                                                keyChar: Hotkey.keyName(key) ?? "key\(key)")
                    if hk.modifiers != mods || hk.keyCode != key || hk.taps != 1 || shiftedText
                        || hk.label != want || hk.displayLabel != want || !hk.isValid
                        || hk.label.unicodeScalars.contains(where: { (0xE000...0xF8FF).contains($0.value) }) {
                        mismatches.append("key\(key)/\(mods) recorded as \(hk) (want \(want))")
                    }
                    chords.append(hk)
                }
            }
        }
        return (chords, cancels, ignored, refused, blocked, mismatches)
    }

    /// Every modifier-only shortcut the recorder saves: each non-empty
    /// modifier set, ×1 and (toggle slots only) ×2.
    static func recordedModifierOnly(style: BindingStyle) -> [Hotkey] {
        modifierSets.dropFirst().flatMap { mods in
            (style == .toggle ? [1, 2] : [1]).compactMap { taps -> Hotkey? in
                guard case .commit(let hk) = HotkeyRecorderView.modifierOutcome(mods, taps: taps, style: style)
                else { return nil }
                return hk
            }
        }
    }

    static let suite = TestSuite(name: "Shortcut configs") { t in
        print("[Shortcut configs]")
        let savedLogGate = Log.enabled
        defer { Log.enabled = savedLogGate }

        recorderSweep(&t)
        slotSweep(&t)
        tableSweep(&t)
        typingAndWatchdog(&t)
        defaultsEndToEnd(&t)
        pairMatrix(&t)
        sharedGestureStop(&t)
    }

    // MARK: - 1. Everything the recorder saves works alone

    static func recorderSweep(_ t: inout Checks) {
        let rec = recordedChords()
        t.check(rec.mismatches.isEmpty, "recorder: Esc cancels, bare typing keys wait, ⇧ + a typing key is "
                + "refused, the rest records as pressed and reads as the key",
                rec.mismatches.prefix(6).joined(separator: "; "))
        let typingKeys = (UInt16(0)...127).filter { !modifierKeycodes.contains($0) && Hotkey.typesText($0) }
        t.check(rec.cancels == 32 && rec.ignored > 0 && !rec.chords.isEmpty && rec.refused == typingKeys.count,
                "recorder sweep covers cancel, ignore, refuse (\(rec.refused)) and record (\(rec.chords.count) chords)")
        // Written out by hand, not derived from the recorder's tables.
        let system = " is a system shortcut.", alone = " alone fires while you type."
        let expectedBlocked = [
            "key8: ⌘ C", "key9: ⌘ V", "key7: ⌘ X", "key6: ⌘ Z", "key0: ⌘ A", "key12: ⌘ Q",
            "key13: ⌘ W", "key4: ⌘ H", "key46: ⌘ M", "key48: ⌘ Tab", "key49: ⌘ Space",
            "key49: ⌃ Space", "key20: ⇧⌘ 3", "key21: ⇧⌘ 4", "key23: ⇧⌘ 5",
        ].map { $0 + system } + [
            "key123: ←", "key124: →", "key125: ↓", "key126: ↑", "key36: Return", "key76: Enter",
            "key48: Tab", "key51: Delete", "key49: Space", "key117: ⌦", "key115: Home", "key119: End",
            "key116: Page Up", "key121: Page Down",
        ].map { $0 + alone }
        t.equal(rec.blocked.sorted(), expectedBlocked.sorted(),
                "recorder refuses exactly the system shortcuts and bare editing keys, saying why")
        recorderSystemShortcuts(&t)
        recorderDoubleTapWait(&t)
        var bareRefused: [String] = []
        for style in [BindingStyle.hold, .toggle] {
            for mods in modifierSets.dropFirst() {
                for taps in style == .toggle ? [1, 2] : [1] {
                    if case .refuse(let why) = HotkeyRecorderView.modifierOutcome(mods, taps: taps, style: style) {
                        bareRefused.append("\(style) \(mods): \(why)")
                    }
                }
            }
        }
        t.equal(bareRefused, ["hold \(shift): ⇧ alone fires while you type.",
                              "hold \(cmd): ⌘ alone fires while you type.",
                              "toggle \(shift): ⇧ alone fires while you type.",
                              "toggle \(cmd): ⌘ alone fires while you type."],
                "recorder refuses only a bare ⇧ or ⌘ hold or single-tap toggle (⇧ ×2 / ⌘ ×2 allowed)")
        // Labels stored by the old recorder read as the key pressed.
        var junk = Sweep()
        for key in HotkeyMonitor.implicitFnKeyCodes.sorted() {
            for physical in modifierSets {
                let stored = Hotkey(modifiers: physical | fn, keyCode: key,
                                    label: Hotkey.makeLabel(modifiers: physical | fn, keyChar: "\u{F729}"))
                let want = Hotkey.makeLabel(modifiers: physical & ~fn, keyChar: Hotkey.keyName(key)!)
                junk.expect(stored.displayLabel == want, "key\(key)/\(physical): \(stored.displayLabel)")
            }
        }
        junk.expect(Hotkey(modifiers: fn, keyCode: 96, label: "fn F5").displayLabel == "F5", "fn F5")
        junk.expect(Hotkey(modifiers: fn, keyCode: 124, label: "fn →").displayLabel == "→", "fn →")
        junk.expect(Hotkey(modifiers: ctrl | fn, keyCode: 115, label: "⌃fn \u{F729}").displayLabel == "⌃ Home", "⌃ Home")
        junk.expect(Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /").displayLabel == "⌥ /", "a letter keeps its label")
        junk.expect(Hotkey.fnDefault.displayLabel == "fn 🌐", "modifier-only keeps its label")
        junk.report(&t, "old stored labels (fn F5, fn →, glyphs) display as the key")

        // Chords, on a hold and a toggle slot.
        var hold = Sweep(), toggle = Sweep(), watchdog = Sweep(), unstick = Sweep(), passThrough = Sweep()
        for hk in rec.chords {
            let key = hk.keyCode!
            do {
                let rig = KeyRig([binding(.dictation, hk)])
                let swallowedDown = rig.press(hk)
                let started = rig.trail.log == ["start dictate"]
                rig.monitor.verifyPhysicalHold()
                let survived = rig.trail.log == ["start dictate"]
                // Another key with the same modifiers still types.
                let other: UInt16 = key == 0 ? 1 : 0
                let otherSwallowed = rig.keyDown(other)
                _ = rig.keyUp(other)
                let swallowedUp = rig.release(hk)
                hold.expect(swallowedDown && swallowedUp && started && rig.trail.log == ["start dictate", "stop dictate"]
                            && !rig.swallowedModifier && rig.trail.maxFiresPerEvent <= 1,
                            "\(hk.label)[\(key)]: \(rig.trail.log)")
                watchdog.expect(survived, "\(hk.label)[\(key)] released by the watchdog while held")
                passThrough.expect(!otherSwallowed, "\(hk.label) swallowed key\(other)")
            }
            do {
                // A release the tap never saw: the watchdog un-sticks it.
                let rig = KeyRig([binding(.dictation, hk)])
                rig.press(hk)
                rig.keys.down.removeAll()
                rig.monitor.verifyPhysicalHold()
                unstick.expect(rig.trail.log == ["start dictate", "stop dictate"], "\(hk.label)[\(key)]: \(rig.trail.log)")
            }
            do {
                let rig = KeyRig([binding(.dictationToggle, hk)])
                let down = rig.press(hk)
                let up = rig.release(hk)
                rig.clock.advance(by: 1)
                rig.tap(hk)
                toggle.expect(down && up && rig.trail.log == ["toggle dictate", "toggle dictate"] && !rig.swallowedModifier,
                              "\(hk.label)[\(key)]: \(rig.trail.log)")
            }
        }
        hold.report(&t, "every recordable chord holds: key swallowed, start once, stop once")
        watchdog.report(&t, "the watchdog keeps every physically held chord (fn-carrying keys included)")
        unstick.report(&t, "the watchdog un-sticks every chord whose release was missed")
        passThrough.report(&t, "a chord never swallows another key with the same modifiers")
        toggle.report(&t, "every recordable chord toggles once per tap, both edges swallowed")

        // Modifier-only, left and right keys, caps lock on and off.
        var modHold = Sweep(), modToggle = Sweep(), modWatch = Sweep()
        for hk in recordedModifierOnly(style: .hold) {
            for right in [false, true] {
                for caps in [false, true] {
                    let rig = KeyRig([binding(.dictation, hk)])
                    rig.right = right; rig.capsLock = caps
                    rig.press(hk)
                    let started = rig.trail.log == ["start dictate"]
                    rig.monitor.verifyPhysicalHold()
                    let survived = rig.trail.log == ["start dictate"]
                    rig.release(hk)
                    modHold.expect(started && rig.trail.log == ["start dictate", "stop dictate"] && !rig.swallowedModifier,
                                   "\(hk.label) right=\(right) caps=\(caps): \(rig.trail.log)")
                    modWatch.expect(survived, "\(hk.label) right=\(right)")
                    let stuck = KeyRig([binding(.dictation, hk)])
                    stuck.right = right
                    stuck.press(hk)
                    stuck.keys.down.removeAll()
                    stuck.monitor.verifyPhysicalHold()
                    modWatch.expect(stuck.trail.log == ["start dictate", "stop dictate"], "\(hk.label) stuck: \(stuck.trail.log)")
                }
            }
        }
        for hk in recordedModifierOnly(style: .toggle) {
            for right in [false, true] {
                let rig = KeyRig([binding(.dictationToggle, hk)])
                rig.right = right
                rig.tap(hk)
                rig.clock.advance(by: 1)
                let once = rig.trail.log
                rig.tap(hk)
                rig.clock.advance(by: 1)
                // A lone single tap never fires a ×2 bind.
                let single = KeyRig([binding(.dictationToggle, hk)])
                single.pressModifiers(hk.modifiers); single.releaseModifiers(hk.modifiers)
                let singleOK = hk.taps == 1 ? single.trail.log == ["toggle dictate"] : single.trail.log.isEmpty
                modToggle.expect(once == ["toggle dictate"] && rig.trail.log == ["toggle dictate", "toggle dictate"]
                                 && singleOK && !rig.swallowedModifier,
                                 "\(hk.label) right=\(right): \(rig.trail.log) single \(single.trail.log)")
            }
        }
        // Letting go of part of a bigger combo lands on a toggle's modifiers
        // without pressing them: not a tap.
        var releaseInto = Sweep()
        for hk in recordedModifierOnly(style: .toggle) where hk.taps == 1 {
            for extra in modifierSets where extra != 0 && extra & hk.modifiers == 0 {
                let rig = KeyRig([binding(.dictationToggle, hk)])
                rig.pressModifiers(extra); rig.pressModifiers(hk.modifiers)
                rig.releaseModifiers(extra); rig.releaseModifiers(hk.modifiers)
                releaseInto.expect(rig.trail.log.isEmpty, "\(hk.label) after releasing \(extra): \(rig.trail.log)")
            }
        }
        releaseInto.report(&t, "releasing into a single-tap toggle's modifiers never toggles")
        modHold.report(&t, "every modifier-only hold: left or right keys, caps lock either way")
        modWatch.report(&t, "the watchdog keeps held modifier-only binds and frees stuck ones")
        modToggle.report(&t, "every modifier-only toggle fires once per gesture; a single tap never fires a ×2")

        // Recorded shortcuts survive Settings, for every slot.
        var roundTrip = Sweep()
        let samples = rec.chords.enumerated().filter { $0.offset % 37 == 0 }.map(\.element)
        // (`readShortcut` is Settings' own load path; one full reload at the
        // end proves it — Settings.init asks SMAppService, too slow per case.)
        let store = InMemoryStore()
        let s = Settings(store: store)
        var last: [BindingSlot: Hotkey] = [:]
        for slot in allSlots {
            guard let spec = slot.spec else { continue }
            for hk in samples + recordedModifierOnly(style: slot.style) {
                s.setShortcut(hk, for: slot)
                let back = spec.readShortcut(from: store)
                roundTrip.expect(back == hk, "\(slot): \(hk.label) read back as \(String(describing: back))")
                last[slot] = hk
            }
        }
        let reloaded = Settings(store: store)
        for (slot, hk) in last { roundTrip.expect(reloaded.shortcut(for: slot) == hk, "\(slot): reload") }
        roundTrip.report(&t, "every recorded shortcut persists on every slot")
    }

    /// Menu shortcuts follow the layout's letter; the defaults and the
    /// shortcuts the app suggests still record.
    static func recorderSystemShortcuts(_ t: inout Checks) {
        typealias R = HotkeyRecorderView
        t.equal(R.keyDownOutcome(keyCode: 8, modifiers: cmd, characters: "c"), .refuse("⌘ C is a system shortcut."),
                "recorder refuses ⌘ C")
        t.check(R.keyDownOutcome(keyCode: 34, modifiers: cmd, characters: "c") == .refuse("⌘ C is a system shortcut.")
                && R.keyDownOutcome(keyCode: 8, modifiers: cmd, characters: "j")
                == .commit(Hotkey(modifiers: cmd, keyCode: 8, label: "⌘ J")),
                "on Dvorak, ⌘ C is refused by its letter and the C key's ⌘ J records")
        t.equal(R.keyDownOutcome(keyCode: 8, modifiers: cmd | shift, characters: "C"),
                .commit(Hotkey(modifiers: cmd | shift, keyCode: 8, label: "⇧⌘ C")), "⇧⌘ C records (only ⌘ C is the system's)")
        t.equal(R.keyDownOutcome(keyCode: 124, modifiers: fn | alt, characters: "\u{F703}"),
                .commit(Hotkey(modifiers: fn | alt, keyCode: 124, label: "⌥ →")), "⌥ → records (only a bare arrow is refused)")
        var allowed = Sweep()
        let chords: [Hotkey?] = [
            Settings.suggestedStreamHotkey, Settings.suggestedStreamToggleHotkey,
            Hotkey(modifiers: ctrl | shift, keyCode: 49, label: "⌃⇧ Space"),
            Hotkey(modifiers: fn, keyCode: 96, label: "F5"), Hotkey(modifiers: alt, keyCode: 49, label: "⌥ Space"),
            Hotkey(modifiers: fn, keyCode: 36, label: "fn Return"),
        ]
        allowed.expect(chords.allSatisfy { $0 != nil }, "the suggested shortcuts decode")
        for hk in chords.compactMap({ $0 }) {
            let chars = Hotkey.keyName(hk.keyCode!) == nil ? String(hk.label.last!) : nil
            let got = R.keyDownOutcome(keyCode: hk.keyCode!, modifiers: hk.modifiers, characters: chars)
            allowed.expect(got == .commit(Hotkey(modifiers: hk.modifiers, keyCode: hk.keyCode, label: hk.displayLabel)),
                           "\(hk.label): \(got)")
        }
        allowed.report(&t, "the suggested shortcuts and allowed chords still record")
    }

    /// Toggle target: tap ⇧, then ⌥ 0.1 s later, then Esc between the two
    /// waits' deadlines. The ⇧ wait used to survive the ⌥ tap (it refused
    /// late and dropped the ⌥ wait's handle) so Esc cancelled nothing and ⌥
    /// saved after cancel.
    static func recorderDoubleTapWait(_ t: inout Checks) {
        /// A recorder on a manual clock that acts on outcomes as the view does.
        func recorder() -> (ShortcutCapture, ManualScheduler, () -> [String]) {
            let clock = ManualScheduler()
            let capture = ShortcutCapture(scheduler: clock)
            var log: [String] = []
            capture.onOutcome = { outcome in
                switch outcome {
                case .cancel: log.append("cancel"); capture.stop()
                case .ignore: break
                case .refuse(let why): log.append("refuse \(why)")
                case .commit(let hk): log.append("save \(hk.label)"); capture.stop()
                }
            }
            capture.start()
            return (capture, clock, { log })
        }
        func tap(_ c: ShortcutCapture, _ mods: UInt64) {
            c.flagsChanged(mods, style: .toggle)
            c.flagsChanged(0, style: .toggle)
        }
        do {
            let (c, clock, log) = recorder()
            tap(c, shift)
            clock.advance(by: 0.1)
            tap(c, alt)
            clock.advance(by: Hotkey.doubleTapInterval - 0.05)   // past ⇧'s deadline, before ⌥'s
            c.keyDown(keyCode: 53, modifiers: 0, characters: nil)
            clock.advance(by: 2)
            t.check(log() == ["cancel"] && !c.isRecording && clock.waiting == 0,
                    "tap ⇧, tap ⌥, Esc: cancels, refuses nothing, saves nothing", "\(log())")
        }
        do {
            let (c, clock, log) = recorder()
            tap(c, shift)
            clock.advance(by: 0.1)
            tap(c, alt)
            clock.advance(by: 2)
            t.equal(log(), ["save ⌥"], "tap ⇧ then ⌥: only the latest tap commits")
        }
        do {
            let (c, clock, log) = recorder()
            tap(c, ctrl)
            clock.advance(by: 0.1)
            tap(c, ctrl)
            clock.advance(by: 2)
            t.equal(log(), ["save ⌃ ×2"], "a quick second tap of the same modifier is ×2")
        }
    }

    // MARK: - 2. Every slot: set, switched off, cleared, unavailable, corrupt

    /// A few shortcuts of each kind, per style.
    static func representatives(_ style: BindingStyle) -> [Hotkey] {
        var list = [
            Hotkey.fnDefault,
            HotkeyRecorderView.modifierHotkey(ctrl, taps: 1),
            HotkeyRecorderView.modifierHotkey(ctrl | alt | shift | cmd | fn, taps: 1),
            Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /"),
            Hotkey(modifiers: fn, keyCode: 96, label: "fn F5"),
            Hotkey(modifiers: fn, keyCode: 124, label: "fn →"),
            Hotkey(modifiers: ctrl | shift, keyCode: 49, label: "⌃⇧ Space"),
        ]
        if style == .toggle { list.append(HotkeyRecorderView.modifierHotkey(ctrl, taps: 2)) }
        return list
    }

    static func slotSweep(_ t: inout Checks) {
        let full = Capabilities(hasServer: true)
        let lite = Capabilities(hasServer: false)
        var fires = Sweep(), off = Sweep(), cleared = Sweep(), edition = Sweep(), corrupt = Sweep()
        let s = Settings(store: InMemoryStore())
        // Unreadable stored data, every slot at once.
        let corruptStore = InMemoryStore()
        for slot in allSlots { if let key = slot.spec?.key { corruptStore.set(Data("not json".utf8), forKey: key) } }
        let corrupted = Settings(store: corruptStore)
        for slot in allSlots {
            guard let spec = slot.spec else { continue }
            for hk in representatives(slot.style) {
                // Only this slot is live.
                s.setEnabled(true, for: slot)
                for other in allSlots where other != slot {
                    s.setShortcut(nil, for: other)
                    s.setEnabled(false, for: other)
                }
                s.setShortcut(hk, for: slot)
                let expected = slot.style == .hold ? ["start \(slot.action)", "stop \(slot.action)"]
                                                   : ["toggle \(slot.action)"]
                func run(_ caps: Capabilities) -> [String] {
                    let rig = KeyRig(HotkeyBinding.effective(from: s, capabilities: caps))
                    rig.tap(hk)
                    rig.clock.advance(by: 1)
                    return rig.trail.log
                }
                fires.expect(run(full) == expected, "\(slot) \(hk.label): \(run(full))")
                let available = slot.action.spec.isAvailable(in: lite)
                edition.expect(run(lite) == (available ? expected : []), "\(slot) \(hk.label) in Lite: \(run(lite))")

                // Switched off: silent — unless the slot has no switch.
                s.setEnabled(false, for: slot)
                off.expect(run(full) == (spec.switchKey == nil ? expected : []), "\(slot) \(hk.label) off: \(run(full))")
                s.setEnabled(true, for: slot)

                // Cleared: silent — unless required (refused, still set).
                s.setShortcut(nil, for: slot)
                let clearedOK = spec.required ? (s.shortcut(for: slot) == hk && run(full) == expected)
                                              : (s.shortcut(for: slot) == nil && run(full).isEmpty)
                cleared.expect(clearedOK, "\(slot) \(hk.label) cleared: \(run(full))")
            }
            // Unreadable stored data: a required slot keeps its default, others read as cleared.
            corrupt.expect(corrupted.shortcut(for: slot) == (spec.required ? spec.defaultHotkey : nil),
                           "\(slot): \(String(describing: corrupted.shortcut(for: slot)))")
            // A decodable but empty shortcut (no modifiers, no key) never fires.
            let empty = Hotkey(modifiers: 0, keyCode: nil, label: "—")
            let rig = KeyRig([binding(slot, empty)])
            for mods in modifierSets.dropFirst() { rig.pressModifiers(mods); rig.releaseModifiers(mods) }
            for key in UInt16(0)...127 where !modifierKeycodes.contains(key) {
                corrupt.expect(!rig.keyDown(key) && !rig.keyUp(key), "\(slot): empty shortcut swallowed key\(key)")
            }
            corrupt.expect(rig.trail.log.isEmpty && !rig.monitor.needsConsume, "\(slot): empty shortcut fired \(rig.trail.log)")
        }
        fires.report(&t, "every slot fires its own action for each kind of shortcut")
        edition.report(&t, "Lite never fires an action it can't run; the rest fire as in Full")
        off.report(&t, "a switched-off slot never fires")
        cleared.report(&t, "a cleared slot never fires; hold-to-dictate can't be cleared")
        corrupt.report(&t, "unreadable or empty stored shortcuts never fire or swallow keys")
    }

    // MARK: - 3. Match tables

    static func tableSweep(_ t: inout Checks) {
        var pool: [Hotkey?] = [nil]
        pool += representatives(.toggle).map { Optional($0) }
        var rng: UInt64 = 0x5EED
        func next(_ n: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % UInt64(n))
        }
        var tables = Sweep()
        for _ in 0..<400 {
            let bindings = allSlots.map { slot -> HotkeyBinding in
                var hk = pool[next(pool.count)]
                if slot.style == .hold, hk?.taps == 2 { hk = nil }
                return binding(slot, hk, enabled: next(4) != 0)
            }
            let live = bindings.filter { $0.enabled && $0.hotkey != nil }
            let wantHolds = live.filter { $0.style == .hold }.sorted { $0.action.priority < $1.action.priority }
                .map { HotkeyMonitor.Target(hotkey: $0.hotkey!, action: $0.action) }
            let wantToggles = live.filter { $0.style == .toggle }.sorted { $0.action.priority < $1.action.priority }
                .map { HotkeyMonitor.Target(hotkey: $0.hotkey!, action: $0.action) }
            let wantConsume = live.contains { !$0.hotkey!.isModifierOnly }
            let m = HotkeyMonitor(armsTap: false)
            m.bindings = bindings
            let first = (m.targets, m.toggleTargets, m.needsConsume)
            m.bindings = bindings.reversed()
            let reversed = (m.targets, m.toggleTargets, m.needsConsume)
            m.bindings = bindings
            tables.expect(first.0 == wantHolds && first.1 == wantToggles && first.2 == wantConsume
                          && reversed.0 == first.0 && reversed.1 == first.1 && reversed.2 == first.2
                          && m.targets == first.0,
                          "\(bindings.map { "\($0.slot):\($0.hotkey?.label ?? "nil")/\($0.enabled)" })")
        }
        tables.report(&t, "match tables: live binds only, priority order, list order irrelevant, consume iff a chord")
    }

    // MARK: - 4. Typing passes through; phantom fn; the watchdog rule

    static func typingAndWatchdog(_ t: inout Checks) {
        // With any modifier-only shortcut bound (every slot style), ordinary
        // typing — any key, bare or shifted, autorepeat — is never swallowed
        // and never fires anything: those binds listen to flagsChanged only.
        var typing = Sweep()
        for style in [BindingStyle.hold, .toggle] {
            let slot = style == .hold ? BindingSlot.dictation : .dictationToggle
            for hk in recordedModifierOnly(style: style) {
                let rig = KeyRig([binding(slot, hk)])
                var swallowed: [UInt16] = []
                for key in UInt16(0)...127 where !modifierKeycodes.contains(key) {
                    if rig.keyDown(key) || rig.keyDown(key, autorepeat: true) || rig.keyUp(key) { swallowed.append(key) }
                }
                typing.expect(swallowed.isEmpty && rig.trail.log.isEmpty && !rig.monitor.needsConsume,
                              "\(style) \(hk.label): swallowed \(swallowed.prefix(4)) fired \(rig.trail.log)")
            }
        }
        typing.report(&t, "modifier-only binds never swallow or react to typing")

        // Phantom fn: every key whose events carry fn (or any flags at all)
        // can never start or stop a modifier-only hold — only flagsChanged can.
        var phantom = Sweep()
        let defaults = Settings(store: InMemoryStore())
        let rig = KeyRig(HotkeyBinding.effective(from: defaults, capabilities: Capabilities(hasServer: true)))
        for key in UInt16(0)...127 where !modifierKeycodes.contains(key) {
            for flags in [fn, fn | CGEventFlags.maskNumericPad.rawValue, ctrl | fn] {
                _ = rig.send(.keyDown, key: key, flags: flags)
                _ = rig.send(.keyUp, key: key, flags: flags)
            }
        }
        phantom.expect(rig.trail.log.isEmpty, "phantom: \(rig.trail.log.prefix(4))")
        rig.tap(.fnDefault)
        phantom.expect(rig.trail.log == ["start dictate", "stop dictate"], "real fn after noise: \(rig.trail.log)")
        phantom.report(&t, "fn-flagged key events never start or stop a hold; real fn still does")

        // The physical-hold rule, exhaustively: every required modifier set ×
        // every left/right/both/none state of each modifier key.
        var rule = Sweep()
        for required in modifierSets {
            for state in 0..<1024 {
                var down: Set<CGKeyCode> = []
                var held: UInt64 = 0
                for (i, bit) in modifierOrder.enumerated() {
                    let s = (state >> (i * 2)) & 3
                    if s & 1 != 0 { down.insert(leftKeys[bit]!.code) }
                    if s & 2 != 0 { down.insert(rightKeys[bit]!.code) }
                    if s != 0 { held |= bit }
                }
                let want = required & held == required
                rule.expect(HotkeyMonitor.physicallyHeld(requiredModifiers: required, keyDown: { down.contains($0) }) == want,
                            "required \(required) held \(held)")
            }
        }
        rule.report(&t, "watchdog: held iff every required modifier has a key down (either side)")
    }

    // MARK: - 5. Fresh-install defaults and the suggestions, end to end

    /// A coordinator on the rig's clock with a fake flow behind it.
    static func endToEnd(_ bindings: [HotkeyBinding], holdDelay: TimeInterval = SessionCoordinatorTests.holdDelay)
        -> (KeyRig, SessionCoordinatorTests.FakeFlows) {
        let clock = ManualScheduler()
        let session = SessionCoordinator(scheduler: clock, holdDelay: { holdDelay })
        let flows = SessionCoordinatorTests.FakeFlows()
        flows.session = session
        session.handler = flows
        let rig = KeyRig(bindings, clock: clock, session: session)
        rig.retained = session
        return (rig, flows)
    }

    /// Use one shortcut the way its slot means it (hold for a second, or
    /// tap, wait, tap) and say whether exactly its own session ran for the
    /// whole gesture.
    static func runsCleanly(_ hk: Hotkey, _ slot: BindingSlot, rig: KeyRig,
                            flows: SessionCoordinatorTests.FakeFlows) -> Bool {
        flows.log = []
        let a = slot.action
        if slot.style == .hold {
            rig.press(hk)
            rig.clock.advance(by: 1)
            let live = flows.capturing && flows.log == ["begin \(a)"]
            rig.release(hk)
            rig.clock.advance(by: 1)
            return live && !flows.capturing && flows.log == ["begin \(a)", "end \(a)"]
        }
        rig.tap(hk)
        rig.clock.advance(by: 1)
        let live = flows.capturing && flows.log == ["begin \(a)"]
        rig.tap(hk)
        rig.clock.advance(by: 1)
        return live && !flows.capturing && flows.log == ["begin \(a)", "end \(a)"]
    }

    static func defaultsEndToEnd(_ t: inout Checks) {
        let full = Capabilities(hasServer: true)
        let fresh = Settings(store: InMemoryStore())
        let freshBindings = HotkeyBinding.effective(from: fresh, capabilities: full)
        for (name, suggest) in [("fresh install", false), ("with the live typing suggestion", true)] {
            let s = suggest ? Settings(store: InMemoryStore()) : fresh
            if suggest {
                s.streamHotkey = Settings.suggestedStreamHotkey
                s.streamToggleHotkey = Settings.suggestedStreamToggleHotkey
            }
            let bindings = HotkeyBinding.effective(from: s, capabilities: full)
            var ok = Sweep()
            for b in bindings where b.enabled {
                guard let hk = b.hotkey else { continue }
                for right in [false, true] {
                    let (rig, flows) = endToEnd(bindings)
                    rig.right = right
                    ok.expect(runsCleanly(hk, b.slot, rig: rig, flows: flows) && rig.trail.maxFiresPerEvent <= 1,
                              "\(b.slot) \(hk.label) right=\(right): \(flows.log) / \(rig.trail.log)")
                }
            }
            ok.report(&t, "\(name): every default shortcut runs exactly its own session")
        }
        // ⌃fn pressed fn-first passes through plain fn (dictate) on the way:
        // the arm is cancelled before it matures, so only the assistant runs.
        let (rig, flows) = endToEnd(freshBindings)
        rig.pressModifiers(fn); rig.pressModifiers(ctrl)
        rig.clock.advance(by: 1)
        let live = flows.log == ["begin assist"]
        rig.releaseModifiers(ctrl | fn)
        rig.clock.advance(by: 1)
        t.check(live && flows.log == ["begin assist", "end assist"],
                "⌃fn pressed fn-first still runs only the assistant", "\(flows.log)")
    }

    // MARK: - 6. Two shortcuts at once: conflicts

    /// A small universe of every kind: modifier-only (incl. sub/supersets),
    /// ×2, chords sharing modifiers, fn-carrying keys, a fn chord.
    static func pairPool(_ style: BindingStyle) -> [Hotkey] {
        var list = [fn, ctrl, alt, ctrl | fn, alt | cmd].map { HotkeyRecorderView.modifierHotkey($0, taps: 1) }
        if style == .toggle { list += [fn, ctrl, ctrl | fn].map { HotkeyRecorderView.modifierHotkey($0, taps: 2) } }
        list += [
            Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /"),
            Hotkey(modifiers: alt, keyCode: 47, label: "⌥ ."),
            Hotkey(modifiers: fn, keyCode: 96, label: "fn F5"),
            Hotkey(modifiers: fn, keyCode: 124, label: "fn →"),
            Hotkey(modifiers: ctrl, keyCode: 49, label: "⌃ Space"),
            Hotkey(modifiers: fn, keyCode: 44, label: "fn /"),
        ]
        return list
    }

    /// Whether `hk` runs cleanly in every order its modifiers can be
    /// pressed (the pool has at most two, so forward and reversed is all).
    static func runsCleanlyInAnyOrder(_ hk: Hotkey, _ slot: BindingSlot, _ bindings: [HotkeyBinding],
                                      reversedTrails: inout [String])
        -> (ran: Bool, rig: KeyRig, flows: SessionCoordinatorTests.FakeFlows) {
        let (rig, flows) = endToEnd(bindings)
        var ran = runsCleanly(hk, slot, rig: rig, flows: flows)
        if ShortcutConflicts.physicalModifiers(hk).nonzeroBitCount > 1 {
            let (back, backFlows) = endToEnd(bindings)
            back.reversedOrder = true
            ran = runsCleanly(hk, slot, rig: back, flows: backFlows) && ran
            reversedTrails = back.trail.log + backFlows.log
        }
        return (ran, rig, flows)
    }

    static func pairMatrix(_ t: inout Checks) {
        let slots = allSlots
        var pairs = Sweep(), perEvent = Sweep(), repeatable = Sweep(), configsOK = Sweep()
        var recorder = Sweep(), rows = Sweep(), shared = Sweep()
        var broken: [ShortcutConflict.Rule: Int] = [:]
        var configs = 0
        // The Settings rows read a real Settings, every slot switched on.
        let s = Settings(store: InMemoryStore())
        for (i, xs) in slots.enumerated() {
            for ys in slots[(i + 1)...] {
                for x in pairPool(xs.style) {
                    for y in pairPool(ys.style) {
                        configs += 1
                        let bindings = [binding(xs, x), binding(ys, y)]
                        var allRan = true
                        for (hk, slot, other, otherSlot) in [(x, xs, y, ys), (y, ys, x, xs)] {
                            var reversed: [String] = []
                            let (ran, rig, flows) = runsCleanlyInAnyOrder(hk, slot, bindings, reversedTrails: &reversed)
                            allRan = allRan && ran
                            let why = ShortcutConflicts.breaks(hk, slot, by: other, otherSlot)
                            if let why { broken[why, default: 0] += 1 }
                            pairs.expect(ran == (why == nil),
                                         "\(slot) \(hk.label) beside \(otherSlot) \(other.label): ran=\(ran) "
                                         + "predicted \(why.map { "\($0)" } ?? "clean") \(flows.log) \(rig.trail.log) "
                                         + "reversed \(reversed)")
                            perEvent.expect(rig.trail.maxFiresPerEvent <= 1 && !rig.swallowedModifier,
                                            "\(slot) \(hk.label) beside \(other.label): \(rig.trail.log)")
                            if configs % 7 == 0 {
                                let (again, againFlows) = endToEnd(bindings.reversed())
                                _ = runsCleanly(hk, slot, rig: again, flows: againFlows)
                                repeatable.expect(again.trail.log == rig.trail.log && againFlows.log == flows.log,
                                                  "\(slot) \(hk.label) beside \(other.label)")
                            }
                            // The recorder: an exact clash is refused, naming the other.
                            let exact = ShortcutConflicts.check(binding(slot, hk), against: bindings)
                                .contains(where: \.isExact)
                            let refusal = ShortcutConflicts.refusal(for: hk, on: slot, among: [binding(otherSlot, other)])
                            recorder.expect(refusal == (exact ? "Used by \(otherSlot.displayName)" : nil),
                                            "\(slot) \(hk.label) beside \(otherSlot) \(other.label): \(refusal ?? "saved")")
                        }
                        // The config as a whole: it works iff the checker passes it.
                        let flagged = !ShortcutConflicts.check(binding(xs, x), against: bindings).isEmpty
                        configsOK.expect(allRan == !flagged, "\(xs) \(x.label) + \(ys) \(y.label): works=\(allRan)")
                        // Both rows warn about a stored clash, naming each other; clean rows say nothing.
                        for slot in slots {
                            let live = slot == xs || slot == ys
                            s.setShortcut(slot == xs ? x : slot == ys ? y : nil, for: slot)
                            s.setEnabled(live, for: slot)
                        }
                        if s.shortcut(for: xs) == x && s.shortcut(for: ys) == y {
                            let full = Capabilities(hasServer: true)
                            let xw = HotkeyRecorderView.warnings(for: xs, settings: s, capabilities: full)
                            let yw = HotkeyRecorderView.warnings(for: ys, settings: s, capabilities: full)
                            let want = flagged ? 1 : 0
                            rows.expect(xw.count == want && yw.count == want
                                        && (!flagged || (xw[0].hasSuffix("\(ys.displayName) (\(y.displayLabel))")
                                                         && yw[0].hasSuffix("\(xs.displayName) (\(x.displayLabel))"))),
                                        "\(xs) \(x.label) + \(ys) \(y.label): \(xw) / \(yw)")
                        }
                        // The advertised pairing: a hold on X beside X ×2.
                        if x.isModifierOnly, y.isModifierOnly, x.modifiers == y.modifiers,
                           (xs.style == .hold && y.taps == 2) || (ys.style == .hold && x.taps == 2) {
                            shared.expect(allRan && !flagged, "\(xs) \(x.label) + \(ys) \(y.label)")
                        }
                    }
                }
            }
        }
        pairs.report(&t, "two shortcuts bound (\(configs) configs, every press order): each runs, "
                     + "or ShortcutConflicts says why not")
        configsOK.report(&t, "every config the checker passes works end to end; every one that fails is flagged")
        perEvent.report(&t, "two shortcuts bound: one event fires at most one action, modifiers never swallowed")
        repeatable.report(&t, "the same config gives the same events and sessions, in any binding order")
        recorder.report(&t, "the recorder refuses exactly the exact clashes, saying \"Used by …\"")
        rows.report(&t, "a stored conflict warns on both rows, naming the other shortcut; clean rows don't")
        shared.report(&t, "a hold on X beside X ×2 runs both, unflagged (fn hold + fn-fn)")
        // The pool is built to hit every conflict rule, so none is untested.
        t.check(broken.count == ShortcutConflict.Rule.allCases.count,
                "the matrix exercises all \(ShortcutConflict.Rule.allCases.count) conflict rules: "
                + broken.map { "\($0.key) ×\($0.value)" }.sorted().joined(separator: ", "))
        // The copy, as the user reads it.
        let dictateHold = binding(.dictation, .fnDefault)
        t.equal(ShortcutConflicts.refusal(for: Hotkey.fnDefault, on: .streamToggle,
                                          among: [dictateHold, binding(.streamToggle, nil)]),
                "Used by Dictation hold", "exact clash copy")
        let stream = binding(.streamToggle, Hotkey(modifiers: alt, keyCode: 47, label: "⌥ ."))
        t.equal(ShortcutConflicts.refusal(for: Hotkey(modifiers: alt, keyCode: 47, label: "⌥ ."), on: .assistant,
                                          among: [stream]), "Used by Live typing toggle", "exact clash copy names the toggle")
        let soft = ShortcutConflicts.check(binding(.dictationToggle, HotkeyRecorderView.modifierHotkey(ctrl | alt, taps: 1)),
                                           against: [binding(.assistant, HotkeyRecorderView.modifierHotkey(ctrl, taps: 1))])
        t.equal(soft.map(\.message), ["Overlaps Assistant (⌃)"], "overlap copy")
    }

    // MARK: - 7. fn hold + fn-fn toggle: a double-tap during the toggle only stops it

    /// One shared gesture's stop, at a hold delay, with exact tap timings:
    /// tap 1 down → up after `firstHeld` → tap 2 down at `secondAt` (nil:
    /// no second tap). Returns the sessions after the toggle was live.
    static func sharedStop(_ mods: UInt64, hold hs: BindingSlot, toggle ts: BindingSlot, delay: TimeInterval,
                           firstHeld: TimeInterval, secondAt: TimeInterval?)
        -> (started: Bool, log: [String], toggleLive: Bool, capturing: Bool) {
        let bindings = [binding(hs, HotkeyRecorderView.modifierHotkey(mods, taps: 1)),
                        binding(ts, HotkeyRecorderView.modifierHotkey(mods, taps: 2))]
        let (rig, flows) = endToEnd(bindings, holdDelay: delay)
        let session = rig.retained as! SessionCoordinator
        // Start: a quick double-tap, then talk.
        rig.pressModifiers(mods, step: 0); rig.clock.advance(by: 0.05)
        rig.releaseModifiers(mods, step: 0); rig.clock.advance(by: 0.05)
        rig.pressModifiers(mods, step: 0); rig.clock.advance(by: 0.05)
        rig.releaseModifiers(mods, step: 0); rig.clock.advance(by: 2)
        let started = session.toggleActive == ts.action && flows.capturing
            && flows.log.last == "begin \(ts.action)" && !flows.log.contains("end \(hs.action)")
        flows.log = []
        // Stop.
        rig.pressModifiers(mods, step: 0)
        if let second = secondAt {
            rig.clock.advance(by: firstHeld)
            rig.releaseModifiers(mods, step: 0)
            rig.clock.advance(by: second - firstHeld)
            rig.pressModifiers(mods, step: 0); rig.clock.advance(by: 0.05)
            rig.releaseModifiers(mods, step: 0)
        } else {
            rig.clock.advance(by: firstHeld)
            rig.releaseModifiers(mods, step: 0)
        }
        rig.clock.advance(by: 1)
        return (started, flows.log, session.toggleActive != nil, flows.capturing)
    }

    static func sharedGestureStop(_ t: inout Checks) {
        let window = Hotkey.doubleTapInterval
        let holds = allSlots.filter { $0.style == .hold }
        let toggles = allSlots.filter { $0.style == .toggle }
        var stop = Sweep(), slow = Sweep(), realHold = Sweep(), quickTap = Sweep()
        for delay in [0, 0.3] {
            for mods in [fn, ctrl, alt | cmd] {
                for hs in holds {
                    for ts in toggles {
                        let H = hs.action, T = ts.action
                        let name = "\(HotkeyRecorderView.modifierHotkey(mods, taps: 1).label) \(hs)+\(ts) delay \(delay)"
                        // A double-tap: second tap anywhere inside the window,
                        // first tap short or held to the window's edge.
                        for second in [0.1, window - 0.001] {
                            for held in [0.05, second - 0.01] {
                                let r = sharedStop(mods, hold: hs, toggle: ts, delay: delay,
                                                   firstHeld: held, secondAt: second)
                                let want = ["end \(T)"] + (held >= delay ? ["begin \(H)", "abort"] : [])
                                stop.expect(r.started && r.log == want && !r.toggleLive && !r.capturing,
                                            "\(name) second \(second) held \(held): \(r.log)")
                            }
                        }
                        // Just past the window: not a double. Tap 1 still only
                        // stopped; tap 2 is a plain quick press.
                        let r = sharedStop(mods, hold: hs, toggle: ts, delay: delay, firstHeld: 0.05,
                                           secondAt: window + 0.001)
                        let tap2 = delay == 0 ? ["begin \(H)", "end \(H)"] : []
                        let want = ["end \(T)"] + (delay == 0 ? ["begin \(H)", "abort"] : []) + tap2
                        slow.expect(r.started && r.log == want && !r.toggleLive && !r.capturing,
                                    "\(name): \(r.log)")
                        // One press released inside the window stops, typing nothing
                        // of its own; held past it, it is a real hold, as before.
                        let inside = sharedStop(mods, hold: hs, toggle: ts, delay: delay,
                                                firstHeld: window - 0.001, secondAt: nil)
                        quickTap.expect(inside.started && inside.log == ["end \(T)", "begin \(H)", "abort"]
                                        && !inside.toggleLive && !inside.capturing, "\(name): \(inside.log)")
                        for held in [window + 0.001, 1.5] {
                            let past = sharedStop(mods, hold: hs, toggle: ts, delay: delay, firstHeld: held, secondAt: nil)
                            realHold.expect(past.started && past.log == ["end \(T)", "begin \(H)", "end \(H)"]
                                            && !past.toggleLive && !past.capturing, "\(name) held \(held): \(past.log)")
                        }
                    }
                }
            }
        }
        stop.report(&t, "a double-tap during its own toggle only stops it: the toggle's audio is handed off, "
                    + "tap 1's hold fragment is thrown away (hold delay 0 and 0.3, window edges)")
        slow.report(&t, "a second tap just past the window is a new press, never a restart")
        quickTap.report(&t, "one quick tap of the shared gesture stops the toggle and types nothing of its own")
        realHold.report(&t, "a press held past the double-tap window closes the toggle and dictates, as before")
    }
}
