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
            monitor.onStart = { [weak session] a in
                trail.log.append("start \(a)"); trail.firesThisEvent += 1; session?.keyDown(a)
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

        func pressModifiers(_ mods: UInt64) {
            for bit in ShortcutConfigTests.modifierOrder where mods & bit != 0 {
                keys.down.insert(modKeys[bit]!.code)
                send(.flagsChanged, key: UInt16(modKeys[bit]!.code), flags: flags)
                clock.advance(by: 0.03)
            }
        }

        func releaseModifiers(_ mods: UInt64) {
            for bit in ShortcutConfigTests.modifierOrder.reversed() where mods & bit != 0 {
                keys.down.remove(modKeys[bit]!.code)
                send(.flagsChanged, key: UInt16(modKeys[bit]!.code), flags: flags)
                clock.advance(by: 0.03)
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
    static func recordedChords() -> (chords: [Hotkey], cancels: Int, ignored: Int, mismatches: [String]) {
        var chords: [Hotkey] = []
        var cancels = 0, ignored = 0
        var mismatches: [String] = []
        for key in UInt16(0)...127 where !modifierKeycodes.contains(key) {
            for physical in modifierSets {
                let mods = physical | (implicitFn(key) ? fn : 0)
                switch HotkeyRecorderView.keyDownOutcome(keyCode: key, modifiers: mods, characters: nil) {
                case .cancel:
                    cancels += 1
                    if key != 53 { mismatches.append("key\(key) cancels") }
                case .ignore:
                    ignored += 1
                    if mods != 0 || Hotkey.isSpecialKey(key) { mismatches.append("key\(key)/\(mods) ignored") }
                case .commit(let hk):
                    if hk.modifiers != mods || hk.keyCode != key || hk.taps != 1
                        || hk.label.isEmpty || hk.label == "—" || !hk.isValid {
                        mismatches.append("key\(key)/\(mods) recorded as \(hk)")
                    }
                    chords.append(hk)
                }
            }
        }
        return (chords, cancels, ignored, mismatches)
    }

    /// Every modifier-only shortcut: each non-empty modifier set, ×1 and
    /// (toggle slots only) ×2.
    static func recordedModifierOnly(style: BindingStyle) -> [Hotkey] {
        modifierSets.dropFirst().flatMap { mods in
            (style == .toggle ? [1, 2] : [1]).map { HotkeyRecorderView.modifierHotkey(mods, taps: $0) }
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
    }

    // MARK: - 1. Everything the recorder saves works alone

    static func recorderSweep(_ t: inout Checks) {
        let rec = recordedChords()
        t.check(rec.mismatches.isEmpty, "recorder: Esc cancels, bare typing keys wait, the rest records as pressed",
                rec.mismatches.prefix(6).joined(separator: "; "))
        t.check(rec.cancels == 32 && rec.ignored > 0 && !rec.chords.isEmpty,
                "recorder sweep covers cancel, ignore and record (\(rec.chords.count) chords)")

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
    static func endToEnd(_ bindings: [HotkeyBinding]) -> (KeyRig, SessionCoordinatorTests.FakeFlows) {
        let clock = ManualScheduler()
        let session = SessionCoordinator(scheduler: clock, holdDelay: { SessionCoordinatorTests.holdDelay })
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
        if style == .toggle { list += [fn, ctrl].map { HotkeyRecorderView.modifierHotkey($0, taps: 2) } }
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

    /// Same gesture to the monitor: a chord's modifiers + key, or a
    /// modifier set and tap count.
    static func sameGesture(_ a: Hotkey, _ b: Hotkey) -> Bool {
        a.modifiers == b.modifiers && a.keyCode == b.keyCode && (a.keyCode != nil || a.taps == b.taps)
    }

    /// The modifier states a shortcut's gesture walks through, in order —
    /// each flagsChanged, with whether a modifier went down to reach it.
    static func walk(_ x: Hotkey) -> [(flags: UInt64, pressed: Bool)] {
        let mods = physicalModifiers(x)
        var states: [(flags: UInt64, pressed: Bool)] = []
        for _ in 0..<(x.isModifierOnly ? max(1, x.taps) : 1) {
            var held: UInt64 = 0
            for bit in modifierOrder where mods & bit != 0 { held |= bit; states.append((held, true)) }
            for bit in modifierOrder.reversed() where mods & bit != 0 { held &= ~bit; states.append((held, false)) }
        }
        return states
    }

    /// Why `x` (on `xs`) can't run cleanly while `y` (on `ys`) is also
    /// bound — nil when it can. The same-gesture rows are the monitor's
    /// documented precedence; the other two are the reported conflicts.
    /// Anything else failing is a regression.
    static func conflict(_ x: Hotkey, _ xs: BindingSlot, with y: Hotkey, _ ys: BindingSlot) -> String? {
        let yFirst = ys.action.priority < xs.action.priority
        if sameGesture(x, y) {
            switch (xs.style, ys.style) {
            case (.hold, .hold): if yFirst { return "same gesture: the earlier hold wins" }
            case (.hold, .toggle):
                if x.keyCode != nil || y.taps <= 1 { return "same gesture: the toggle wins" }
            case (.toggle, .toggle): if yFirst { return "same gesture: the earlier toggle wins" }
            case (.toggle, .hold): break
            }
        }
        // Modifier toggles are matched by modifiers alone: ⌃ and ⌃ ×2 on two
        // toggles is one gesture to the monitor.
        let sameToggleModifiers = xs.style == .toggle && ys.style == .toggle
            && x.isModifierOnly && y.isModifierOnly && x.modifiers == y.modifiers
        if sameToggleModifiers && yFirst { return "same modifiers: the earlier toggle wins" }
        // Pressing x's modifiers presses y's single-tap toggle on the way.
        let states = walk(x)
        if ys.style == .toggle, y.isModifierOnly, y.taps <= 1, !sameGesture(x, y), !sameToggleModifiers,
           states.contains(where: { $0.pressed && $0.flags == y.modifiers }) {
            return "a single-tap modifier toggle inside another gesture"
        }
        // x's toggle gesture engages y's modifier hold, whose press or
        // release then ends the toggle's session (SessionCoordinator: "a
        // held key closes a live toggle at once").
        if xs.style == .toggle, ys.style == .hold, y.isModifierOnly, y.modifiers != 0 {
            // A modifier-only toggle's own (last) press never reaches the hold matcher.
            let trigger = x.isModifierOnly ? states.lastIndex(where: { $0.pressed }) : nil
            for (i, state) in states.enumerated()
            where i != trigger && state.flags != 0 && state.flags & y.modifiers == y.modifiers {
                return "a toggle through a modifier hold"
            }
        }
        return nil
    }

    static func pairMatrix(_ t: inout Checks) {
        let slots = allSlots
        var pairs = Sweep(), perEvent = Sweep(), repeatable = Sweep()
        var broken: [String: Int] = [:]
        var configs = 0
        for (i, xs) in slots.enumerated() {
            for ys in slots[(i + 1)...] {
                for x in pairPool(xs.style) {
                    for y in pairPool(ys.style) {
                        configs += 1
                        let bindings = [binding(xs, x), binding(ys, y)]
                        for (hk, slot, other, otherSlot) in [(x, xs, y, ys), (y, ys, x, xs)] {
                            let (rig, flows) = endToEnd(bindings)
                            let ran = runsCleanly(hk, slot, rig: rig, flows: flows)
                            let why = conflict(hk, slot, with: other, otherSlot)
                            if let why { broken[why, default: 0] += 1 }
                            pairs.expect(ran == (why == nil),
                                         "\(slot) \(hk.label) beside \(otherSlot) \(other.label): ran=\(ran) "
                                         + "predicted \(why ?? "clean") \(flows.log) \(rig.trail.log)")
                            perEvent.expect(rig.trail.maxFiresPerEvent <= 1 && !rig.swallowedModifier,
                                            "\(slot) \(hk.label) beside \(other.label): \(rig.trail.log)")
                            if configs % 7 == 0 {
                                let (again, againFlows) = endToEnd(bindings.reversed())
                                _ = runsCleanly(hk, slot, rig: again, flows: againFlows)
                                repeatable.expect(again.trail.log == rig.trail.log && againFlows.log == flows.log,
                                                  "\(slot) \(hk.label) beside \(other.label)")
                            }
                        }
                    }
                }
            }
        }
        pairs.report(&t, "two shortcuts bound (\(configs) configs): each runs, or fails only by a known conflict")
        perEvent.report(&t, "two shortcuts bound: one event fires at most one action, modifiers never swallowed")
        repeatable.report(&t, "the same config gives the same events and sessions, in any binding order")
        // The pool is built to hit every conflict rule, so none is untested.
        t.check(broken.count == 6, "the matrix exercises all 6 conflict rules: "
                + broken.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
    }
}
