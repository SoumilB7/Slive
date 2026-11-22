import CoreGraphics
import Foundation
import SliveTestKit

/// G1 recorder sub-simulator ("sim-recorder"): the shortcut recorder's real
/// press handling (`ShortcutCapture`, on a manual clock) driven by seeded
/// clicks, modifier taps, chords, Esc and gaps, with the view's own rules
/// around it (Record toggles, a save or Esc ends the recording and drops the
/// outcome handler, an exact clash is refused).
///
/// - F16: nothing is saved from a press made before the latest Esc or stop,
///   and no ×2 wait outlives the recording.
/// - F13: a saved shortcut is never one on a literal list of system shortcuts.
@MainActor
enum SimRecorder {
    static let family = GauntletFamily(name: "sim-recorder", seeded: true) { run in
        SimKit.runSeeds(&run, family: "sim-recorder", salt: 0x5EC0_4DE4, invariants: invariants,
                        generate: generate, play: play, script: script)
    }

    static let invariants = [
        SimKit.Invariant(id: "F16", name: "after Esc nothing is saved, and no ×2 wait outlives the recording"),
        SimKit.Invariant(id: "F13", name: "a saved shortcut is never a system shortcut (literal list)"),
    ]

    static let fn = CGEventFlags.maskSecondaryFn.rawValue
    static let ctrl = CGEventFlags.maskControl.rawValue
    static let alt = CGEventFlags.maskAlternate.rawValue
    static let shift = CGEventFlags.maskShift.rawValue
    static let cmd = CGEventFlags.maskCommand.rawValue

    /// Written out by hand (gauntlet.md G7), not taken from the recorder's
    /// own table: ⌘C/V/X/Z/Q/W/Tab/Space and the bare arrows.
    static let systemList: [(modifiers: UInt64, keyCode: UInt16)] =
        ([8, 9, 7, 6, 12, 13, 48, 49] as [UInt16]).map { (modifiers: cmd, keyCode: $0) }
        + ([123, 124, 125, 126] as [UInt16]).map { (modifiers: UInt64(0), keyCode: $0) }

    static func isSystemShortcut(_ hk: Hotkey) -> Bool {
        guard let key = hk.keyCode else { return false }
        let pressed = Hotkey.implicitFnKeyCodes.contains(key) ? hk.modifiers & ~fn : hk.modifiers
        return systemList.contains { $0.keyCode == key && $0.modifiers == pressed }
    }

    // MARK: - Script

    struct Config {
        let style: BindingStyle
        var slot: BindingSlot { style == .toggle ? .dictationToggle : .stream }
    }

    enum Event {
        /// Click the Record button: starts a recording, or cancels the one running.
        case record
        /// Press these modifiers one by one, then let go of them.
        case tap(UInt64)
        /// Hold the modifiers, press the key, let go.
        case chord(UInt64, UInt16)
        case esc
        case wait(TimeInterval)
    }

    static let tapPool: [UInt64] = [fn, ctrl, alt, shift, cmd, ctrl | alt, alt | shift, fn | ctrl]
    static let chordMods: [UInt64] = [0, cmd, cmd, alt, ctrl, shift, cmd | shift, ctrl | alt]
    /// ⌘ menu letters, Tab, Space, arrows, F5, Return, and plain letters.
    static let keyPool: [UInt16] = [8, 9, 7, 6, 12, 13, 48, 49, 0, 38, 44, 47, 123, 124, 125, 126, 96, 36, 1, 20]
    static let gaps: [TimeInterval] = [0.02, 0.05, 0.1, 0.2, 0.3, 0.45, 0.8]

    static func generate(_ dice: inout SimKit.Dice) -> (Config, [Event]) {
        let config = Config(style: dice.chance(65) ? .toggle : .hold)
        var events: [Event] = [.record]
        for _ in 0..<(18 + dice.below(14)) {
            let e: Event = dice.weighted([
                (14, .record), (26, .tap(dice.pick(tapPool))),
                (24, .chord(dice.pick(chordMods), dice.pick(keyPool))),
                (10, .esc), (26, .wait(dice.pick(gaps))),
            ])
            events.append(e)
        }
        return (config, events)
    }

    static func label(_ e: Event) -> String {
        switch e {
        case .record: return "click Record"
        case .tap(let m): return "tap \(Hotkey.makeLabel(modifiers: m, keyChar: nil))"
        case .chord(let m, let k): return "press \(Hotkey.makeLabel(modifiers: m, keyChar: Hotkey.keyName(k) ?? usChar(k)))"
        case .esc: return "Esc"
        case .wait(let s): return String(format: "wait %.2fs", s)
        }
    }

    static func script(_ config: Config, _ events: [Event]) -> String {
        let world = World(config)
        var lines = ["    a \(config.style) shortcut"]
        for e in events {
            lines.append("    \(SimKit.stamp(world.now)) \(label(e))")
            world.apply(e)
        }
        world.finish()
        lines.append("    → saved: \(world.saves.map { "\($0.hotkey.label) (recording \($0.epoch))" })")
        return lines.joined(separator: "\n")
    }

    /// The US character a key types (what `charactersIgnoringModifiers` gives).
    static func usChar(_ key: UInt16) -> String {
        let map: [UInt16: String] = [0: "a", 1: "s", 6: "z", 7: "x", 8: "c", 9: "v", 12: "q", 13: "w",
                                     20: "3", 38: "j", 44: "/", 47: "."]
        return map[key] ?? "?"
    }

    // MARK: - World

    /// One recorder row: the real `ShortcutCapture` plus the view's handling
    /// of its outcomes, mirrored from `HotkeyRecorderView`.
    @MainActor final class World {
        let config: Config
        let clock = ManualScheduler()
        let capture: ShortcutCapture
        private(set) var recording = false
        /// Recordings started so far; a save is tagged with the one it landed in.
        private(set) var epoch = 0
        /// Modifier sets and chords pressed in each recording.
        private var pressedMods: [Int: [UInt64]] = [:]
        private var pressedChords: [Int: [(UInt64, UInt16)]] = [:]
        private(set) var saves: [(hotkey: Hotkey, epoch: Int)] = []
        /// Waits still armed right after an Esc or a stop.
        private(set) var waitsAfterStop: [String] = []
        private static let bindings = HotkeyBinding.effective(from: Settings(store: InMemoryStore(), loginItemEnabled: { false }),
                                                              capabilities: Capabilities(hasServer: true))

        init(_ config: Config) {
            self.config = config
            capture = ShortcutCapture(scheduler: clock)
        }

        var now: TimeInterval { clock.now.timeIntervalSinceReferenceDate }

        private func start() {
            recording = true
            epoch += 1
            capture.onOutcome = { [weak self] in self?.applyOutcome($0) }
            capture.start()
        }

        /// The view's `cancel()`: stop, and drop the handler.
        private func stop(_ why: String) {
            recording = false
            capture.stop()
            capture.onOutcome = { _ in }
            if clock.waiting > 0 { waitsAfterStop.append("\(clock.waiting) wait(s) armed after \(why)") }
        }

        private func applyOutcome(_ outcome: HotkeyRecorderView.KeyOutcome) {
            switch outcome {
            case .cancel: stop("Esc")
            case .ignore, .refuse: break
            case .commit(let hk):
                if ShortcutConflicts.refusal(for: hk, on: config.slot, among: Self.bindings) != nil { return }
                saves.append((hk, epoch))
                stop("a save")
            }
        }

        private func flags(_ mods: UInt64) {
            if recording { capture.flagsChanged(mods, style: config.style) }
            clock.advance(by: 0.02)
        }

        /// Modifier bits in press order (released in reverse).
        private func bits(_ mods: UInt64) -> [UInt64] { [ctrl, alt, shift, cmd, fn].filter { mods & $0 != 0 } }

        func apply(_ e: Event) {
            switch e {
            case .record:
                if recording { stop("a click on Record") } else { start() }
            case .tap(let mods):
                if recording { pressedMods[epoch, default: []].append(mods) }
                var held: UInt64 = 0
                for b in bits(mods) { held |= b; flags(held) }
                for b in bits(mods).reversed() { held &= ~b; flags(held) }
            case .chord(let mods, let key):
                let carried = mods | (Hotkey.implicitFnKeyCodes.contains(key) ? fn : 0)
                if recording {
                    pressedMods[epoch, default: []].append(mods)
                    pressedChords[epoch, default: []].append((carried, key))
                }
                var held: UInt64 = 0
                for b in bits(mods) { held |= b; flags(held) }
                if recording {
                    let chars = Hotkey.keyName(key) != nil ? "\u{F729}" : usChar(key)
                    capture.keyDown(keyCode: key, modifiers: carried, characters: chars)
                }
                clock.advance(by: 0.03)
                for b in bits(mods).reversed() { held &= ~b; flags(held) }
            case .esc:
                if recording { capture.keyDown(keyCode: 53, modifiers: 0, characters: "\u{1B}") }
                clock.advance(by: 0.02)
            case .wait(let s):
                clock.advance(by: s)
            }
        }

        func finish() { clock.advance(by: 2) }

        /// Saves not explained by a press in their own recording.
        var leakedSaves: [String] {
            saves.compactMap { s in
                let hk = s.hotkey
                if let key = hk.keyCode {
                    let ok = (pressedChords[s.epoch] ?? []).contains { $0.0 == hk.modifiers && $0.1 == key }
                    return ok ? nil : "\(hk.label) saved in recording \(s.epoch) with no such press in it"
                }
                let presses = (pressedMods[s.epoch] ?? []).filter { $0 == hk.modifiers }.count
                return presses >= hk.taps ? nil : "\(hk.label) saved in recording \(s.epoch) after \(presses) such press(es)"
            }
        }
    }

    static func play(_ config: Config, _ events: [Event]) -> SimKit.Findings {
        let world = World(config)
        for e in events { world.apply(e) }
        world.finish()
        var found = SimKit.Findings()
        let leaks = world.leakedSaves + world.waitsAfterStop
        found.expect(leaks.isEmpty, "F16", leaks.joined(separator: "; "))
        let system = world.saves.map(\.hotkey).filter(isSystemShortcut)
        found.expect(system.isEmpty, "F13", "saved \(system.map(\.label))")
        return found
    }
}
