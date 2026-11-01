import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

private let fn = Fixtures.fn
private let ctrl = Fixtures.ctrl
private let cmd = Fixtures.cmd
private let alt = Fixtures.alt

@MainActor
enum HotkeyMatchingTests {
    static let suite = TestSuite(name: "Hotkey matching") { t in
        print("[Hotkey matching]")
        var started: [HotkeyAction] = []
        var stopped: [HotkeyAction] = []
        var m = Fixtures.makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })

        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(fn))
        t.equal(started, [.dictate], "exact fn starts dictate")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))
        t.equal(stopped, [.dictate], "release stops dictate")

        started = []; stopped = []
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(ctrl))
        t.equal(started, [.stream], "exact ⌃ starts stream")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))

        // Dominance: both gestures held at once → dictate (highest priority) wins.
        started = []; stopped = []
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(fn | ctrl))
        t.equal(started, [.dictate], "dictate dominates fn+⌃")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))

        // Exact match beats subset priority: retarget stream to exactly fn+⌃.
        started = []; stopped = []
        m = Fixtures.makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        m.streamHotkey = Hotkey(modifiers: fn | ctrl, keyCode: nil, label: "fn⌃")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(fn | ctrl))
        t.equal(started, [.stream], "exact fn+⌃ prefers stream over fn-subset")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))

        // Switching gestures in one transition stops the old, starts the new.
        started = []; stopped = []
        m = Fixtures.makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(fn))
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(ctrl))
        t.equal(started, [.dictate, .stream], "switch starts new action")
        t.equal(stopped, [.dictate], "switch stops old action")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))

        // Unrelated modifier does nothing.
        started = []; stopped = []
        m = Fixtures.makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(cmd))
        t.check(started.isEmpty && stopped.isEmpty, "⌘ alone does nothing")

        // Slive's own tagged keystrokes must never stop an active stream.
        started = []; stopped = []
        m = Fixtures.makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(ctrl))
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0, marker: true))
        t.check(stopped.isEmpty, "synthetic marker ignored (stream survives own typing)")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))

        // Chords: the key must be swallowed both ways and drive start/stop.
        started = []; stopped = []
        m = Fixtures.makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        m.hotkey = Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /")
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 44, keyDown: true)!
        down.flags = CGEventFlags(rawValue: alt)
        t.check(m.handle(type: .keyDown, event: down), "chord key-down swallowed")
        t.equal(started, [.dictate], "chord starts dictate")
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 44, keyDown: false)!
        up.flags = CGEventFlags(rawValue: alt)
        t.check(m.handle(type: .keyUp, event: up), "chord key-up swallowed")
        t.equal(stopped, [.dictate], "chord release stops dictate")

        // A plain letter passes through untouched.
        let plain = CGEvent(keyboardEventSource: nil, virtualKey: 4, keyDown: true)!
        plain.flags = []
        t.check(!m.handle(type: .keyDown, event: plain), "plain key passes through")

        // Tap-to-toggle: a modifier toggle fires on the exact-match DOWN edge
        // only; releases do nothing; and its gesture never doubles as a hold.
        started = []; stopped = []
        var toggled: [HotkeyAction] = []
        m = Fixtures.makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        m.streamHotkey = nil
        m.dictateToggleHotkey = Hotkey(modifiers: ctrl, keyCode: nil, label: "⌃")
        m.onToggle = { toggled.append($0) }
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(ctrl))
        t.equal(toggled, [.dictate], "modifier toggle fires on its down edge")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))
        t.equal(toggled, [.dictate], "releasing the toggle modifier does nothing")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(ctrl))
        t.equal(toggled, [.dictate, .dictate], "second tap toggles again")
        t.check(started.isEmpty && stopped.isEmpty,
              "a toggle-bound gesture never starts a hold")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))
        // The unrelated hold key still holds normally alongside the toggle.
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(fn))
        t.equal(started, [.dictate], "hold bind still works beside a toggle bind")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))

        // Chord toggle: fires once on keyDown (not autorepeat), swallows both
        // key events.
        started = []; stopped = []; toggled = []
        m = Fixtures.makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        m.streamToggleHotkey = Hotkey(modifiers: alt, keyCode: 40, label: "⌥ K")
        m.onToggle = { toggled.append($0) }
        let tDown = CGEvent(keyboardEventSource: nil, virtualKey: 40, keyDown: true)!
        tDown.flags = CGEventFlags(rawValue: alt)
        t.check(m.handle(type: .keyDown, event: tDown), "chord toggle key-down swallowed")
        t.equal(toggled, [.stream], "chord toggle fires on key-down")
        let tRepeat = CGEvent(keyboardEventSource: nil, virtualKey: 40, keyDown: true)!
        tRepeat.flags = CGEventFlags(rawValue: alt)
        tRepeat.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        t.check(m.handle(type: .keyDown, event: tRepeat), "autorepeat still swallowed")
        t.equal(toggled, [.stream], "autorepeat does NOT re-fire the toggle")
        let tUp = CGEvent(keyboardEventSource: nil, virtualKey: 40, keyDown: false)!
        tUp.flags = CGEventFlags(rawValue: alt)
        t.check(m.handle(type: .keyUp, event: tUp), "chord toggle key-up swallowed")
        t.check(started.isEmpty && stopped.isEmpty, "chord toggle never engages a hold")

        // Double-tap binds: the same physical key can hold-dictate AND
        // double-tap-toggle. The ×2 toggle fires only on the second quick
        // down edge; the hold still sees the gesture (its arm is cancelled
        // app-side when the double fires).
        started = []; stopped = []; toggled = []
        m = Fixtures.makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        m.streamHotkey = nil
        m.streamToggleHotkey = Hotkey(modifiers: fn, keyCode: nil, label: "fn ×2", taps: 2)
        m.onToggle = { toggled.append($0) }
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(fn))    // tap 1 down
        t.check(toggled.isEmpty, "first tap of a ×2 bind does not toggle")
        t.equal(started, [.dictate], "…but the hold bind still sees the gesture")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))     // tap 1 up
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(fn))    // tap 2 down (fast)
        t.equal(toggled, [.stream], "second quick tap fires the ×2 toggle")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(fn))    // tap 3 (pair consumed)
        t.equal(toggled, [.stream], "the pair is consumed — a third tap starts fresh")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))

        // Pure double-tap timing rule.
        let now = Date()
        t.check(HotkeyMonitor.isDoubleTap(previousMods: fn, previousAt: now.addingTimeInterval(-0.2),
                                        mods: fn, now: now),
              "two taps 0.2s apart are a double")
        t.check(!HotkeyMonitor.isDoubleTap(previousMods: fn, previousAt: now.addingTimeInterval(-1.0),
                                         mods: fn, now: now),
              "a slow second tap is not a double")
        t.check(!HotkeyMonitor.isDoubleTap(previousMods: ctrl, previousAt: now.addingTimeInterval(-0.2),
                                         mods: fn, now: now),
              "different gestures never pair into a double")
        // Old saved binds (no taps field) decode as single-tap.
        if let data = "{\"modifiers\":\(fn),\"label\":\"fn\"}".data(using: .utf8),
           let legacy = try? JSONDecoder().decode(Hotkey.self, from: data) {
            t.equal(legacy.taps, 1, "legacy binds decode as single-tap")
        } else {
            t.check(false, "legacy binds decode as single-tap", "decode failed")
        }

        // macOS synthesizes arrow/Home/End/Page keys as fn+key: their keyDown
        // and keyUp events CARRY maskSecondaryFn without fn ever being
        // touched. They must never read as the fn hotkey (this was the
        // "dictation starts out of nowhere" bug).
        started = []; stopped = []
        m = Fixtures.makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        let arrowDown = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)!
        arrowDown.flags = CGEventFlags(rawValue: fn)
        t.check(!m.handle(type: .keyDown, event: arrowDown) && started.isEmpty,
              "fn-flagged arrow key-down cannot phantom-start dictation")
        let arrowUp = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: false)!
        arrowUp.flags = CGEventFlags(rawValue: fn)
        _ = m.handle(type: .keyUp, event: arrowUp)
        t.check(started.isEmpty && stopped.isEmpty,
              "fn-flagged arrow key-up is equally inert")
        // The real gesture still works after the arrow noise.
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(fn))
        t.equal(started, [.dictate], "real fn flagsChanged still starts dictate")
        _ = m.handle(type: .flagsChanged, event: Fixtures.flagsEvent(0))
        t.equal(stopped, [.dictate], "and still releases")

        // The stuck-hold watchdog asks about physical KEYS (synthetic typing
        // pollutes flag state — the bug that killed every held stream once
        // live typing began). Injected probe = the hardware.
        t.check(!HotkeyMonitor.physicallyHeld(requiredModifiers: fn, keyDown: { _ in false }),
              "watchdog releases when fn's key is physically up")
        t.check(HotkeyMonitor.physicallyHeld(requiredModifiers: fn, keyDown: { $0 == 63 }),
              "watchdog holds while the fn key is physically down")
        t.check(!HotkeyMonitor.physicallyHeld(requiredModifiers: fn | ctrl, keyDown: { $0 == 63 }),
              "watchdog releases when only part of a combo remains down")
        t.check(HotkeyMonitor.physicallyHeld(requiredModifiers: ctrl, keyDown: { $0 == 62 }),
              "either left or right variant of a modifier counts as held")
        t.check(HotkeyMonitor.physicallyHeld(requiredModifiers: fn | ctrl,
                                           keyDown: { $0 == 63 || $0 == 59 }),
              "combos hold while every required modifier has a key down")
    }
}
