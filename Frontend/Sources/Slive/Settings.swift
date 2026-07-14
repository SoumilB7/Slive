import CoreGraphics
import Foundation
import ServiceManagement

/// App-wide, persisted preferences. Backed by `UserDefaults`; observable so the
/// SwiftUI Settings window stays in sync.
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Keys {
        static let hotkey = "hotkey"
        static let assistantHotkey = "assistantHotkey"
        static let streamHotkey = "streamHotkey"
        static let assistantConfig = "assistantConfig"
        static let launchAtLogin = "launchAtLogin"
        static let autoInsert = "autoInsert"
        static let hotwords = "hotwords"
        static let contextPrompt = "contextPrompt"
        static let holdActivationDelay = "holdActivationDelay"
        static let overlayOpacity = "overlayOpacity"
        static let whisperModel = "whisperModel"
        static let continuousModel = "continuousModel"
        static let continuousTypeCPS = "continuousTypeCPS"
        static let didFirstRun = "didFirstRun"
    }

    /// Fired whenever the dictation hotkey changes, so the monitor can re-target.
    var onHotkeyChange: ((Hotkey) -> Void)?
    /// Fired whenever the assistant hotkey changes (nil = disabled).
    var onAssistantHotkeyChange: ((Hotkey?) -> Void)?
    /// Fired whenever the live-streaming dictation hotkey changes (nil = disabled).
    var onStreamHotkeyChange: ((Hotkey?) -> Void)?
    /// Fired when the transcription model changes, so the backend can restart
    /// with the new FLOWY_WHISPER_MODEL.
    var onWhisperModelChange: ((String) -> Void)?
    /// Fired when the continuous (live streaming) dictation model changes, so the
    /// registry can preload the new one and evict any model no longer referenced.
    var onContinuousModelChange: ((String) -> Void)?

    /// The user-recorded push-to-talk shortcut. Persisted as JSON.
    @Published var hotkey: Hotkey {
        didSet {
            if let data = try? JSONEncoder().encode(hotkey) {
                UserDefaults.standard.set(data, forKey: Keys.hotkey)
            }
            onHotkeyChange?(hotkey)
        }
    }

    /// Optional second shortcut that routes your speech through an LLM instead of
    /// typing it back. nil = assistant mode disabled. Persisted as JSON.
    @Published var assistantHotkey: Hotkey? {
        didSet {
            if let hk = assistantHotkey, let data = try? JSONEncoder().encode(hk) {
                UserDefaults.standard.set(data, forKey: Keys.assistantHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.assistantHotkey)
            }
            onAssistantHotkeyChange?(assistantHotkey)
        }
    }

    /// Optional third shortcut for live-streaming dictation: transcribes as you
    /// speak and types the words straight into the focused field. nil = disabled.
    /// Persisted as JSON.
    @Published var streamHotkey: Hotkey? {
        didSet {
            if let hk = streamHotkey, let data = try? JSONEncoder().encode(hk) {
                UserDefaults.standard.set(data, forKey: Keys.streamHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.streamHotkey)
            }
            onStreamHotkeyChange?(streamHotkey)
        }
    }

    /// Non-secret assistant settings (provider, model, base URL, system prompt).
    /// API keys are stored separately in the Keychain. Persisted as JSON.
    @Published var assistantConfig: AssistantConfig {
        didSet {
            if let data = try? JSONEncoder().encode(assistantConfig) {
                UserDefaults.standard.set(data, forKey: Keys.assistantConfig)
            }
        }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }

    /// When enabled, transcripts are inserted straight into the focused editable
    /// text field (when possible) instead of surfacing the copy box.
    @Published var autoInsert: Bool {
        didSet { UserDefaults.standard.set(autoInsert, forKey: Keys.autoInsert) }
    }

    /// Custom vocabulary — names, jargon, acronyms — sent with each request so
    /// the model spells them the way the user expects.
    @Published var hotwords: String {
        didSet { UserDefaults.standard.set(hotwords, forKey: Keys.hotwords) }
    }

    /// A sentence of context that steers the transcription (optional).
    @Published var contextPrompt: String {
        didSet { UserDefaults.standard.set(contextPrompt, forKey: Keys.contextPrompt) }
    }

    /// How long you must hold the key before recording begins (seconds). Brief
    /// taps under this do nothing. Default 0.2s.
    @Published var holdActivationDelay: Double {
        didSet { UserDefaults.standard.set(holdActivationDelay, forKey: Keys.holdActivationDelay) }
    }

    /// Opacity of the floating overlay chrome — the pill, transcribing dots, and
    /// answer box backgrounds. 1 = solid; lower = more see-through. Text stays
    /// fully opaque so answers remain readable. Default 0.92.
    @Published var overlayOpacity: Double {
        didSet { UserDefaults.standard.set(overlayOpacity, forKey: Keys.overlayOpacity) }
    }

    /// WhisperKit model the on-device (Neural Engine) transcriber loads. Changing
    /// it reloads WhisperKit; the new model downloads once.
    @Published var whisperModel: String {
        didSet {
            UserDefaults.standard.set(whisperModel, forKey: Keys.whisperModel)
            onWhisperModelChange?(whisperModel)
        }
    }

    /// WhisperKit model used by continuous (live streaming) dictation — fully
    /// independent of `whisperModel`. When set to the same name, the two share one
    /// resident instance; when different, both load. Changing it reloads its model.
    @Published var continuousModel: String {
        didSet {
            UserDefaults.standard.set(continuousModel, forKey: Keys.continuousModel)
            onContinuousModelChange?(continuousModel)
        }
    }

    /// Characters-per-second the live typist eases the field toward during
    /// continuous dictation. `>= 120` means "Instant" (whole diff flushed at once).
    /// Default 30.
    @Published var continuousTypeCPS: Double {
        didSet { UserDefaults.standard.set(continuousTypeCPS, forKey: Keys.continuousTypeCPS) }
    }

    /// Ground truth: true once the event tap has actually delivered a keystroke.
    /// Proof that Input Monitoring is genuinely working, regardless of the
    /// cache-prone IOHIDCheckAccess API.
    @Published var hotkeyActive = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.hotkey),
           let decoded = try? JSONDecoder().decode(Hotkey.self, from: data) {
            hotkey = decoded
        } else {
            hotkey = .fnDefault
        }
        if let data = UserDefaults.standard.data(forKey: Keys.assistantHotkey),
           let decoded = try? JSONDecoder().decode(Hotkey.self, from: data) {
            assistantHotkey = decoded
        } else {
            assistantHotkey = nil
        }
        if let data = UserDefaults.standard.data(forKey: Keys.streamHotkey),
           let decoded = try? JSONDecoder().decode(Hotkey.self, from: data) {
            streamHotkey = decoded
        } else {
            streamHotkey = nil
        }
        if let data = UserDefaults.standard.data(forKey: Keys.assistantConfig),
           let decoded = try? JSONDecoder().decode(AssistantConfig.self, from: data) {
            assistantConfig = decoded
        } else {
            assistantConfig = .default
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        // Default TRUE: absent key means the user hasn't opted out yet.
        if UserDefaults.standard.object(forKey: Keys.autoInsert) == nil {
            autoInsert = true
        } else {
            autoInsert = UserDefaults.standard.bool(forKey: Keys.autoInsert)
        }
        hotwords = UserDefaults.standard.string(forKey: Keys.hotwords) ?? ""
        contextPrompt = UserDefaults.standard.string(forKey: Keys.contextPrompt) ?? ""
        if UserDefaults.standard.object(forKey: Keys.holdActivationDelay) == nil {
            holdActivationDelay = 0.2
        } else {
            holdActivationDelay = UserDefaults.standard.double(forKey: Keys.holdActivationDelay)
        }
        if UserDefaults.standard.object(forKey: Keys.overlayOpacity) == nil {
            overlayOpacity = 0.92
        } else {
            overlayOpacity = UserDefaults.standard.double(forKey: Keys.overlayOpacity)
        }
        // Default to the bundled tiny model so the first launch works instantly
        // and fully offline — the user can switch to a bigger one in Settings.
        whisperModel = UserDefaults.standard.string(forKey: Keys.whisperModel) ?? "tiny.en"
        // Continuous dictation defaults to the same bundled tiny model (so both
        // sections share one instance until the user changes either one).
        continuousModel = UserDefaults.standard.string(forKey: Keys.continuousModel) ?? "tiny.en"
        if UserDefaults.standard.object(forKey: Keys.continuousTypeCPS) == nil {
            continuousTypeCPS = 30
        } else {
            continuousTypeCPS = UserDefaults.standard.double(forKey: Keys.continuousTypeCPS)
        }
    }

    // MARK: - Assistant API keys (Keychain-backed)

    /// Read a provider's stored API key (nil/empty if none).
    func apiKey(for provider: AssistantProvider) -> String {
        KeychainStore.get(provider.keychainAccount) ?? ""
    }

    /// Store (or clear, when empty) a provider's API key. Trimmed so a stray
    /// newline/space (common when pasting) can't produce an illegal HTTP header.
    /// Also nudges observers so the settings UI reflects the change.
    func setAPIKey(_ key: String, for provider: AssistantProvider) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set(clean, for: provider.keychainAccount)
        objectWillChange.send()
    }

    var isFirstRun: Bool {
        !UserDefaults.standard.bool(forKey: Keys.didFirstRun)
    }

    func markFirstRunComplete() {
        UserDefaults.standard.set(true, forKey: Keys.didFirstRun)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Slive: launch-at-login toggle failed: \(error)")
        }
    }
}
