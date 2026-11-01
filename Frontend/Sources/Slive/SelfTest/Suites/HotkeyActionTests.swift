import AVFoundation
import Foundation
import SliveTestKit

@MainActor
enum HotkeyActionTests {
    static let suite = TestSuite(name: "Hotkey actions") { t in
        print("[Hotkey actions]")
        let savedLogGate = Log.enabled
        defer { Log.enabled = savedLogGate }

        // The spec list: one per action, in priority order, every cue playable.
        t.equal(ActionSpec.all.map(\.action), [.dictate, .assist, .stream],
                "one spec per action, priority order")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 1, interleaved: false)!
        for spec in ActionSpec.all {
            t.check(spec.action.spec.action == spec.action, "\(spec.name): spec maps back to its action")
            t.check(!spec.slots.isEmpty, "\(spec.name): has a shortcut slot")
            let buffer = FeedbackPlayer.makeTone(spec.cue.tone, format: format,
                                                 sampleRate: 44_100, gain: 0.25)
            t.check((buffer?.frameLength ?? 0) > 0, "\(spec.name): its cue renders a tone")
            t.check(!spec.cue.fallbackSound.isEmpty, "\(spec.name): its cue has a fallback sound")
        }
        t.equal(HotkeyAction.dictate.spec.cue, .dhum, "dictation cue: dhum")
        t.equal(HotkeyAction.stream.spec.cue, .dhum, "live typing shares the dictation dhum")
        t.equal(HotkeyAction.assist.spec.cue, .deepDhum, "assistant cue: deeper dhum")
        t.check(HotkeyAction.dictate.spec.alwaysQueues && HotkeyAction.stream.spec.alwaysQueues
                && !HotkeyAction.assist.spec.alwaysQueues,
                "spoken words always queue; an assistant request may be superseded")
        let slotKeys = ActionSpec.all.flatMap(\.slots).compactMap(\.spec?.key)
        t.equal(Set(slotKeys).count, slotKeys.count, "every slot has its own key")

        // Capabilities: Lite drops the assistant, Full keeps everything.
        let full = Capabilities(hasServer: true)
        let lite = Capabilities(hasServer: false)
        t.check(full.server && full.assistant && full.providers && full.localModels && full.training,
                "Full has every capability")
        t.check(!lite.server && !lite.assistant && !lite.providers && !lite.localModels && !lite.training,
                "Lite has none of the server's")
        t.equal(Capabilities.current.server, Edition.hasServer, "current capabilities follow the edition")
        t.check(!HotkeyAction.assist.spec.isAvailable(in: lite)
                && HotkeyAction.dictate.spec.isAvailable(in: lite)
                && HotkeyAction.stream.spec.isAvailable(in: lite),
                "Lite runs dictation and live typing, not the assistant")

        // Default config → the monitor's match tables.
        typealias Target = HotkeyMonitor.Target
        let s = Settings(store: InMemoryStore())
        let m = HotkeyMonitor()
        m.bindings = HotkeyBinding.effective(from: s, capabilities: full)
        t.equal(m.targets, [Target(hotkey: .fnDefault, action: .dictate),
                            Target(hotkey: Settings.defaultAssistantHotkey!, action: .assist)],
                "default holds: fn dictates, ⌃fn asks")
        t.equal(m.toggleTargets, [Target(hotkey: Settings.defaultDictateToggle!, action: .dictate)],
                "default toggle: ⌃ ×2 dictates")
        t.check(!m.needsConsume, "default config listens only (no chord)")

        m.bindings = HotkeyBinding.effective(from: s, capabilities: lite)
        t.equal(m.targets, [Target(hotkey: .fnDefault, action: .dictate)], "Lite: no assistant hold")

        // Live typing suggested + switches: order and enablement follow the bindings.
        s.streamHotkey = Settings.suggestedStreamHotkey
        s.streamToggleHotkey = Settings.suggestedStreamToggleHotkey
        m.bindings = HotkeyBinding.effective(from: s, capabilities: full)
        t.equal(m.targets.map(\.action), [.dictate, .assist, .stream], "holds in priority order")
        t.equal(m.toggleTargets.map(\.action), [.dictate, .stream], "toggles in priority order")
        t.check(m.needsConsume, "a chord shortcut needs a consuming tap")
        s.dictateHoldOn = false
        s.streamToggleOn = false
        m.bindings = HotkeyBinding.effective(from: s, capabilities: full)
        t.equal(m.targets.map(\.action), [.assist, .stream], "a switched-off hold isn't matched")
        t.equal(m.toggleTargets.map(\.action), [.dictate], "a switched-off toggle isn't matched")

        // Priority comes from the action, not the list order.
        m.bindings = HotkeyBinding.effective(from: s, capabilities: full).reversed()
        t.equal(m.targets.map(\.action), [.assist, .stream], "reversed list, same priority")
    }
}
