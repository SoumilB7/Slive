import CoreGraphics
import Foundation
import SliveTestKit

/// G1 key layer ("sim-keys"): seeded raw keyboard events (flagsChanged,
/// keyDown, keyUp) into the real `HotkeyMonitor` (never armed: no tap) and
/// the real `SessionCoordinator` behind it, on a manual clock. The world
/// presses and releases physical keys; some events never reach the tap (a
/// dropped key-up, Secure Input). The release watchdog ticks every 0.2 s
/// while a hold is engaged, as its timer does.
///
/// - sim-keys.stuck: once every key is physically up and the watchdog has
///   run, no hold is engaged and the fn hold works again (the chord stuck
///   after a dropped key-up from the Oct 29 audit; not a numbered finding).
/// - F17: a toggle tap never discards a hold older than the false-start
///   window (the tap in a long hold's release tail).
@MainActor
enum SimKeys {
    static let family = GauntletFamily(name: "sim-keys", seeded: true) { run in
        SimKit.runSeeds(&run, family: "sim-keys", salt: 0x0E1E_C7ED, invariants: invariants,
                        generate: generate, play: play, script: script)
    }

    static let invariants = [
        SimKit.Invariant(id: "sim-keys.stuck",
                         name: "all keys up + a watchdog tick: nothing held, the fn hold works again"),
        SimKit.Invariant(id: "F17", name: "a toggle tap never discards a hold older than the false-start window"),
    ]

    static let fn = CGEventFlags.maskSecondaryFn.rawValue
    static let ctrl = CGEventFlags.maskControl.rawValue
    static let alt = CGEventFlags.maskAlternate.rawValue
    static let shift = CGEventFlags.maskShift.rawValue

    // MARK: - Configs

    /// One shortcut setup. fn hold-to-dictate is in every one (the probe).
    struct Config {
        let name: String
        let bindings: [HotkeyBinding]
        let holdDelay: TimeInterval
    }

    static func binding(_ slot: BindingSlot, _ hk: Hotkey) -> HotkeyBinding {
        HotkeyBinding(action: slot.action, style: slot.style, hotkey: hk, enabled: true)
    }

    static let setups: [(String, [HotkeyBinding])] = [
        ("fn hold · ⌥ / hold · fn ×2 toggle · ⌥ . toggle", [
            binding(.dictation, .fnDefault),
            binding(.stream, Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /")),
            binding(.dictationToggle, HotkeyRecorderView.modifierHotkey(fn, taps: 2)),
            binding(.streamToggle, Hotkey(modifiers: alt, keyCode: 47, label: "⌥ .")),
        ]),
        ("fn hold · ⌃ hold · ⌃⌥ toggle", [
            binding(.dictation, .fnDefault),
            binding(.stream, HotkeyRecorderView.modifierHotkey(ctrl, taps: 1)),
            binding(.streamToggle, HotkeyRecorderView.modifierHotkey(ctrl | alt, taps: 1)),
        ]),
        ("fn hold · ⌃⇧ Space hold · F5 toggle · ⌥ ×2 toggle", [
            binding(.dictation, .fnDefault),
            binding(.stream, Hotkey(modifiers: ctrl | shift, keyCode: 49, label: "⌃⇧ Space")),
            binding(.dictationToggle, Hotkey(modifiers: fn, keyCode: 96, label: "F5")),
            binding(.streamToggle, HotkeyRecorderView.modifierHotkey(alt, taps: 2)),
        ]),
    ]

    // MARK: - Script

    /// A physical key: a modifier (its left key) or a key code.
    enum Key: Equatable {
        case mod(UInt64)
        case key(UInt16)
    }

    enum Event {
        /// `delivered` false: the tap never saw it (the key still moved).
        case down(Key, delivered: Bool)
        case up(Key, delivered: Bool)
        /// Secure Input on: no event reaches the tap until it's off.
        case secureInput(Bool)
        case wait(TimeInterval)
    }

    static let holdTimes: [TimeInterval] = [0.1, 0.3, 0.6, 1.3, 2.5]
    static let gaps: [TimeInterval] = [0.01, 0.03, 0.05, 0.08, 0.2, 0.5, 1.0]

    static func modifierKeys(_ mods: UInt64) -> [Key] {
        ShortcutConfigTests.modifierOrder.filter { mods & $0 != 0 }.map { Key.mod($0) }
    }

    /// The physical modifiers a shortcut is pressed with (a key that carries
    /// fn is pressed without it).
    static func pressed(_ hk: Hotkey) -> [Key] { modifierKeys(ShortcutConfigTests.physicalModifiers(hk)) }

    static func generate(_ dice: inout SimKit.Dice) -> (Config, [Event]) {
        let setup = dice.pick(setups)
        let config = Config(name: setup.0, bindings: setup.1, holdDelay: dice.pick([0, 0.15, 0.3]))
        let holds = setup.1.filter { $0.style == .hold }.compactMap(\.hotkey)
        let toggles = setup.1.filter { $0.style == .toggle }.compactMap(\.hotkey)
        var events: [Event] = []
        /// A key-up the tap misses now and then.
        func up(_ k: Key, _ dice: inout SimKit.Dice) -> Event { .up(k, delivered: !dice.chance(8)) }
        for _ in 0..<(8 + dice.below(8)) {
            switch dice.weighted([(40, 0), (30, 1), (10, 2), (10, 3), (10, 4)]) {
            case 0:   // a hold gesture
                let hk = dice.pick(holds)
                var keys = pressed(hk)
                if dice.chance(50) { keys.reverse() }
                events += keys.map { .down($0, delivered: true) }
                if let code = hk.keyCode { events.append(.down(.key(code), delivered: true)) }
                events.append(.wait(dice.pick(holdTimes)))
                var ups = keys + (hk.keyCode.map { [Key.key($0)] } ?? [])
                if dice.chance(50) { ups.reverse() }   // modifier released before the key, or after
                for k in ups { events.append(up(k, &dice)) }
            case 1:   // a toggle tap (both taps of a ×2)
                guard let hk = toggles.isEmpty ? nil : dice.pick(toggles) else { continue }
                for tap in 0..<max(1, hk.taps) {
                    if tap > 0 { events.append(.wait(0.08)) }
                    let keys = pressed(hk)
                    events += keys.map { .down($0, delivered: true) }
                    if let code = hk.keyCode {
                        events.append(.down(.key(code), delivered: true))
                        events.append(up(.key(code), &dice))
                    }
                    events.append(.wait(0.03))
                    for k in keys.reversed() { events.append(up(k, &dice)) }
                }
            case 2:   // ordinary typing in between
                let code: UInt16 = dice.pick([0, 1, 44, 47, 49])
                events.append(.down(.key(code), delivered: true))
                events.append(up(.key(code), &dice))
            case 3:   // Secure Input comes and goes
                events.append(.secureInput(true))
                events.append(.wait(dice.pick(gaps)))
                events.append(.secureInput(false))
            default:
                break
            }
            events.append(.wait(dice.pick(gaps)))
        }
        return (config, events)
    }

    static func name(_ k: Key) -> String {
        switch k {
        case .mod(let m): return Hotkey.makeLabel(modifiers: m, keyChar: nil)
        case .key(let c): return Hotkey.keyName(c) ?? SimRecorder.usChar(c)
        }
    }

    static func label(_ e: Event) -> String {
        switch e {
        case .down(let k, let d): return "\(name(k)) down" + (d ? "" : " (missed)")
        case .up(let k, let d): return "\(name(k)) up" + (d ? "" : " (missed)")
        case .secureInput(let on): return "Secure Input \(on ? "on" : "off")"
        case .wait(let s): return String(format: "wait %.2fs", s)
        }
    }

    static func script(_ config: Config, _ events: [Event]) -> String {
        let world = World(config)
        var lines = ["    \(config.name), hold delay \(config.holdDelay)s"]
        for e in events {
            lines.append("    \(SimKit.stamp(world.now)) \(label(e))")
            world.apply(e)
        }
        let end = world.finish()
        lines.append("    → coordinator: \(world.flows.log.map(\.1))")
        lines.append("    → after letting go: \(end.isEmpty ? "clean" : end.joined(separator: "; "))")
        return lines.joined(separator: "\n")
    }

    // MARK: - World

    /// What the coordinator asked for, timestamped. Reports starts as the
    /// real modes do (the false-start rule reads them).
    @MainActor final class Flows: SessionHandler {
        weak var session: SessionCoordinator?
        let clock: ManualScheduler
        private(set) var log: [(TimeInterval, String)] = []
        private(set) var capturing = false
        private(set) var begunAt: TimeInterval?
        /// Aborts of a session older than the false-start window.
        private(set) var lostHolds: [String] = []

        init(clock: ManualScheduler) { self.clock = clock }
        var now: TimeInterval { clock.now.timeIntervalSinceReferenceDate }

        func beginSession(_ action: HotkeyAction) {
            log.append((now, "begin \(action)"))
            capturing = true
            begunAt = now
            if action == .stream { session?.liveStarted() } else { session?.recordingStarted() }
        }
        func endSession(_ action: HotkeyAction) {
            log.append((now, "end \(action)"))
            if action == .stream { _ = session?.liveEnded() }
            capturing = false
            begunAt = nil
        }
        func abortSession() {
            log.append((now, "abort"))
            if capturing, let begunAt, now - begunAt >= SessionCoordinator.falseStartWindow {
                lostHolds.append(String(format: "a %.2fs-old session aborted at t=%.2f", now - begunAt, now))
            }
            capturing = false
            begunAt = nil
        }
        var isCapturing: Bool { capturing }
    }

    @MainActor final class World {
        let clock = ManualScheduler()
        let session: SessionCoordinator
        let flows: Flows
        let rig: ShortcutConfigTests.KeyRig
        private var secure = false
        /// Physical press order, so the end lets go of keys before modifiers.
        private var held: [Key] = []

        init(_ config: Config) {
            session = SessionCoordinator(scheduler: clock, holdDelay: { config.holdDelay })
            flows = Flows(clock: clock)
            flows.session = session
            session.handler = flows
            rig = ShortcutConfigTests.KeyRig(config.bindings, clock: clock, session: session)
            rig.retained = session
        }

        var now: TimeInterval { clock.now.timeIntervalSinceReferenceDate }

        /// The hold the monitor reports engaged (a start with no stop yet).
        var engaged: String? {
            var current: String?
            for line in rig.trail.log {
                if line.hasPrefix("start ") { current = String(line.dropFirst(6)) }
                if line.hasPrefix("stop "), current == String(line.dropFirst(5)) { current = nil }
            }
            return current
        }

        private func code(_ bit: UInt64) -> UInt16 { UInt16(ShortcutConfigTests.leftKeys[bit]!.code) }

        func press(_ k: Key, delivered: Bool) {
            guard !held.contains(k) else { return }
            held.append(k)
            let send = delivered && !secure
            switch k {
            case .mod(let bit):
                rig.keys.down.insert(CGKeyCode(code(bit)))
                if send { rig.send(.flagsChanged, key: code(bit), flags: rig.flags) }
            case .key(let c):
                if send { _ = rig.keyDown(c) } else { rig.keys.down.insert(CGKeyCode(c)) }
            }
        }

        func release(_ k: Key, delivered: Bool) {
            guard let i = held.firstIndex(of: k) else { return }
            held.remove(at: i)
            let send = delivered && !secure
            switch k {
            case .mod(let bit):
                rig.keys.down.remove(CGKeyCode(code(bit)))
                if send { rig.send(.flagsChanged, key: code(bit), flags: rig.flags) }
            case .key(let c):
                if send { _ = rig.keyUp(c) } else { rig.keys.down.remove(CGKeyCode(c)) }
            }
        }

        /// Time passes; the watchdog ticks every 0.2 s while a hold is engaged.
        func wait(_ seconds: TimeInterval) {
            var left = seconds
            while left > 1e-9 {
                let step = min(0.2, left)
                clock.advance(by: step)
                left -= step
                if engaged != nil { rig.monitor.verifyPhysicalHold() }
            }
        }

        func apply(_ e: Event) {
            switch e {
            case .down(let k, let d): press(k, delivered: d)
            case .up(let k, let d): release(k, delivered: d)
            case .secureInput(let on): secure = on
            case .wait(let s): wait(s)
            }
        }

        /// Let go of everything (Secure Input off, every release seen), let
        /// the watchdog run, then try the fn hold. Returns what's wrong.
        func finish() -> [String] {
            secure = false
            for k in held.reversed() where k != .mod(fn) { release(k, delivered: true) }
            if held.contains(.mod(fn)) { release(.mod(fn), delivered: true) }
            wait(1)
            var problems: [String] = []
            if let engaged { problems.append("\(engaged) still engaged") }
            if flows.capturing && session.toggleActive == nil { problems.append("a session still capturing") }
            let mark = flows.log.count
            press(.mod(fn), delivered: true)
            wait(1)
            let began = flows.capturing && flows.log.last?.1 == "begin dictate"
            release(.mod(fn), delivered: true)
            wait(1)
            let ended = !flows.capturing && flows.log.last?.1 == "end dictate"
            if !began || !ended {
                problems.append("the fn hold no longer works (it gave \(flows.log.dropFirst(mark).map(\.1)))")
            }
            rig.monitor.stop()   // drops the watchdog timer the monitor scheduled
            return problems
        }
    }

    static func play(_ config: Config, _ events: [Event]) -> SimKit.Findings {
        let world = World(config)
        for e in events { world.apply(e) }
        let problems = world.finish()
        var found = SimKit.Findings()
        found.expect(problems.isEmpty, "sim-keys.stuck", problems.joined(separator: "; "))
        found.expect(world.flows.lostHolds.isEmpty, "F17", world.flows.lostHolds.joined(separator: "; "))
        return found
    }
}
