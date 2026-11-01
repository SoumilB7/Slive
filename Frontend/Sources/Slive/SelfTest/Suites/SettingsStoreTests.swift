import Combine
import Foundation

private let alt = Fixtures.alt

@MainActor
enum SettingsStoreTests {
    static let suite = TestSuite(name: "Settings store") { t in
        print("[Settings store]")
        // Settings.init applies the verbose-log gate; keep the real one.
        let savedLogGate = Log.enabled
        defer { Log.enabled = savedLogGate }

        // Fresh install: every default exactly as before the declarative move.
        let store = InMemoryStore()
        let s = Settings(store: store)
        t.equal(s.hotkey, Hotkey.fnDefault, "default: hold fn dictates")
        t.equal(s.assistantHotkey, Settings.defaultAssistantHotkey, "default: ⌃fn asks")
        t.equal(s.streamHotkey, nil, "default: no live-typing hold")
        t.equal(s.dictateToggleHotkey, Settings.defaultDictateToggle, "default: ⌃ ×2 toggles dictation")
        t.equal(s.streamToggleHotkey, nil, "default: no live-typing toggle")
        t.check(s.dictateHoldOn && s.dictateToggleOn && s.streamHoldOn && s.streamToggleOn,
                "default: all four switches on")
        t.equal(s.assistantConfig, AssistantConfig.default, "default: assistant config")
        t.equal(s.autoInsert, true, "default: autoInsert on")
        t.equal(s.hotwords, "", "default: no hotwords")
        t.equal(s.contextPrompt, "", "default: no context prompt")
        t.equal(s.holdActivationDelay, 0, "default: hold delay 0")
        t.equal(s.overlayOpacity, 0.4, "default: overlay opacity 0.4")
        t.equal(s.pillOnRight, false, "default: pill at the bottom")
        t.equal(s.whisperModel, "tiny.en", "default: tiny.en dictates")
        t.equal(s.continuousModel, "parakeet-ultra", "default: parakeet-ultra live types")
        t.equal(s.continuousTypeCPS, 80, "default: 80 cps live typing")
        t.equal(s.verboseLogging, false, "default: verbose logs off")
        t.equal(s.reportProblems, true, "default: problem reports offered")
        t.equal(s.captureEdits, true, "default: capture on")
        t.equal(s.captureMaxGB, 2.0, "default: 2 GB capture cap")
        t.equal(s.echoCancellation, false, "default: echo cancellation off")
        t.equal(s.inputDeviceUID, "", "default: system mic")
        t.equal(s.inputDeviceName, "", "default: no mic name")
        t.equal(s.groundTruthProvider, .openai, "default: OpenAI labels")
        t.equal(s.groundTruthModel, "gpt-audio", "default: gpt-audio")
        t.equal(s.groundTruthBaseURL, "", "default: no base URL")
        t.equal(s.groundTruthPrompt, "", "default: server's label prompt")
        t.equal(s.consensusPrompt, "", "default: server's consensus prompt")
        t.equal(s.groundTruthRecipe, .consensus, "default: consensus recipe")
        t.equal(s.localQuantized, true, "default: int8 local models")
        t.equal(s.localMemLimitGB, Settings.localMemDefaultGB(ramGB: MachineProfile.ramGB),
                "default: memory limit fits this Mac")
        t.equal(s.speedTier, SpeedTier.relaxed.rawValue, "default: relaxed tier")
        t.check(s.isFirstRun, "default: first run")
        t.check(store.values.isEmpty, "reading defaults writes nothing")

        // Every key is today's key — renaming one would orphan saved settings.
        let slotKeys = ActionSpec.all.flatMap(\.slots).compactMap(\.spec)
            .flatMap { [$0.key] + ($0.switchKey.map { [$0] } ?? []) }
        let keys = Set(s.storedSettings.map(\.key) + slotKeys)
        let expected: Set<String> = [
            "hotkey", "assistantHotkey", "streamHotkey", "dictateToggleHotkey", "streamToggleHotkey",
            "dictateHoldOn", "dictateToggleOn", "streamHoldOn", "streamToggleOn",
            "assistantConfig", "autoInsert", "hotwords", "contextPrompt", "holdActivationDelay",
            "overlayOpacity", "pillOnRight", "whisperModel", "continuousModel", "continuousTypeCPS",
            "verboseLogging", "reportProblems", "captureEdits", "captureMaxGB", "echoCancellation",
            "inputDeviceUID", "inputDeviceName", "groundTruthProvider", "groundTruthModel",
            "groundTruthBaseURL", "groundTruthPrompt", "consensusPrompt", "groundTruthRecipe",
            "localQuantized", "localMemLimitGB", "speedTier",
        ]
        t.equal(keys, expected, "settings keys unchanged")
        t.equal(s.storedSettings.count + slotKeys.count, expected.count, "no key declared twice")

        // Writes land under those keys and read back in a new instance.
        s.overlayOpacity = 0.7
        s.autoInsert = false
        s.groundTruthRecipe = .single
        s.assistantConfig.baseURL = "http://x"
        s.speedTier = 2
        s.markFirstRunComplete()
        t.equal(store.values["overlayOpacity"] as? Double, 0.7, "a Double persists under its key")
        let again = Settings(store: store)
        t.equal(again.overlayOpacity, 0.7, "stored Double reads back")
        t.equal(again.autoInsert, false, "stored false beats a true default")
        t.equal(again.groundTruthRecipe, .single, "stored enum reads back")
        t.equal(again.assistantConfig.baseURL, "http://x", "stored JSON reads back")
        t.equal(again.speedTier, 2, "stored Int reads back")
        t.check(!again.isFirstRun, "first-run flag persists")

        // Migrations and clamps apply to stored values.
        let old = Settings(store: InMemoryStore([
            "groundTruthModel": "gpt-4o-audio-preview",
            "localMemLimitGB": 500.0,
            "groundTruthProvider": "no-such-provider",
        ]))
        t.equal(old.groundTruthModel, "gpt-audio", "retired gpt-4o-audio-preview migrates")
        t.equal(old.localMemLimitGB, Settings.localMemMaxGB(ramGB: MachineProfile.ramGB),
                "stored memory limit clamps to this Mac")
        t.equal(old.groundTruthProvider, .openai, "unknown provider falls back to the default")

        // Hotkeys: both legacy "cleared" forms read as nil; one form is written.
        let garbage = Data("not json".utf8)
        let legacy = Settings(store: InMemoryStore([
            "assistantHotkey": Data(),            // cleared, written as empty data
            "dictateToggleHotkey": Data(),
            "streamToggleHotkey": garbage,        // unreadable reads as cleared too
            // streamHotkey: cleared by removing the key (its default is nil)
            "hotkey": Data(),                     // the primary key can't be cleared
        ]))
        t.equal(legacy.assistantHotkey, nil, "empty data reads as a cleared assistant key")
        t.equal(legacy.dictateToggleHotkey, nil, "empty data reads as a cleared toggle")
        t.equal(legacy.streamToggleHotkey, nil, "unreadable data reads as cleared")
        t.equal(legacy.streamHotkey, nil, "a removed key reads as cleared (default nil)")
        t.equal(legacy.hotkey, Hotkey.fnDefault, "unreadable primary key falls back to fn")

        let clearStore = InMemoryStore()
        let clearing = Settings(store: clearStore)
        let chord = Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /")
        clearing.streamHotkey = chord
        t.check(clearStore.values["streamHotkey"] is Data, "a set shortcut persists as JSON")
        clearing.streamHotkey = nil
        clearing.assistantHotkey = nil
        t.equal(clearStore.values["streamHotkey"] as? Data, Data(), "clearing writes empty data (stream)")
        t.equal(clearStore.values["assistantHotkey"] as? Data, Data(), "clearing writes empty data (assistant)")
        let reread = Settings(store: clearStore)
        t.check(reread.streamHotkey == nil && reread.assistantHotkey == nil,
                "cleared shortcuts stay cleared (not reset to defaults)")
        clearing.setShortcut(nil, for: .dictation)
        t.equal(clearing.hotkey, Hotkey.fnDefault, "the primary key ignores a clear")
        t.equal(clearStore.values["hotkey"] as? Data, nil, "…and writes nothing")

        // Change events: synchronous, in set order, to every subscriber, with
        // the new value already readable.
        let live = Settings(store: InMemoryStore())
        var first: [SettingsChange] = []
        var second: [SettingsChange] = []
        var seenModel = ""
        var willChange = 0
        var bag: Set<AnyCancellable> = []
        live.changes.sink { change in
            first.append(change)
            if change == .dictationModel { seenModel = live.whisperModel }
        }.store(in: &bag)
        live.changes.sink { second.append($0) }.store(in: &bag)
        live.objectWillChange.sink { willChange += 1 }.store(in: &bag)

        live.whisperModel = "small.en"
        t.equal(first, [.dictationModel], "model change delivered synchronously")
        t.equal(seenModel, "small.en", "subscriber reads the new value")
        live.streamHotkey = chord
        live.streamHoldOn = false
        live.dictateToggleHotkey = nil
        live.continuousModel = "parakeet-v2"
        live.hotwords = "Slive"   // no live effect → no event
        let order: [SettingsChange] = [.dictationModel, .bindings, .bindings, .bindings, .continuousModel]
        t.equal(first, order, "events arrive in set order; plain settings emit none")
        t.equal(second, order, "every subscriber gets every event")
        t.equal(willChange, 6, "every set notifies SwiftUI")

        // Side effect via didSet still runs.
        live.verboseLogging = true
        t.check(Log.enabled, "verboseLogging turns the log gate on")
        live.verboseLogging = false
    }
}
