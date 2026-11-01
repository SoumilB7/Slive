import Combine
import CoreGraphics
import Foundation
import ServiceManagement

/// What changed, for subscribers of `Settings.changes`. Delivered
/// synchronously, on the thread that set the value (main), right after the
/// new value is stored — so a subscriber reads it back already current.
enum SettingsChange: Equatable {
    /// Any shortcut or its on/off switch (see `bindings`).
    case bindings
    /// `whisperModel` — the dictation model.
    case dictationModel
    /// `continuousModel` — the live-typing model.
    case continuousModel
}

/// App-wide, persisted preferences. Backed by a `KeyValueStore`
/// (`UserDefaults.standard` in the app); observable so the SwiftUI Settings
/// window stays in sync.
///
/// Adding a setting = one `@Stored(key, default:)` line (+ `emits:` if
/// something must react live, + a `didSet` for a side effect). Shortcuts are
/// declared by `ActionSpec` instead and reached through `shortcut(for:)`.
final class Settings: ObservableObject, StoredSettingsOwner {
    static let shared = Settings()

    let store: KeyValueStore
    let objectWillChange = ObservableObjectPublisher()

    /// Every change that something outside the Settings window must act on.
    /// Any number of subscribers; delivery is synchronous (no scheduler).
    var changes: AnyPublisher<SettingsChange, Never> { changeSubject.eraseToAnyPublisher() }
    private let changeSubject = PassthroughSubject<SettingsChange, Never>()

    func publish(_ change: SettingsChange) { changeSubject.send(change) }

    // MARK: Shortcuts (declared by ActionSpec)

    private var shortcuts: [BindingSlot: Hotkey?] = [:]
    private var switches: [BindingSlot: Bool] = [:]

    /// The recorded shortcut for a slot (nil = not set / cleared).
    func shortcut(for slot: BindingSlot) -> Hotkey? {
        shortcuts[slot] ?? nil
    }

    /// Record or clear a slot's shortcut. A required slot (hold-to-dictate)
    /// can't be cleared.
    func setShortcut(_ hotkey: Hotkey?, for slot: BindingSlot) {
        guard let spec = slot.spec, hotkey != nil || !spec.required else { return }
        objectWillChange.send()
        shortcuts[slot] = .some(hotkey)
        spec.writeShortcut(hotkey, to: store)
        publish(.bindings)
    }

    /// A slot's on/off switch (slots without one are always on).
    func isEnabled(_ slot: BindingSlot) -> Bool {
        switches[slot] ?? true
    }

    func setEnabled(_ on: Bool, for slot: BindingSlot) {
        guard let key = slot.spec?.switchKey else { return }
        objectWillChange.send()
        switches[slot] = on
        on.write(to: store, key: key)
        publish(.bindings)
    }

    /// Every slot as a binding, in `ActionSpec` order. What the HotkeyMonitor
    /// matches (after capability filtering).
    var bindings: [HotkeyBinding] {
        ActionSpec.all.flatMap(\.slots).map {
            HotkeyBinding(action: $0.action, style: $0.style,
                          hotkey: shortcut(for: $0), enabled: isEnabled($0))
        }
    }

    /// The user-recorded push-to-talk shortcut. Persisted as JSON.
    var hotkey: Hotkey {
        get { shortcut(for: .dictation) ?? .fnDefault }
        set { setShortcut(newValue, for: .dictation) }
    }

    /// Optional second shortcut that routes your speech through an LLM instead of
    /// typing it back. nil = assistant mode disabled. Persisted as JSON.
    var assistantHotkey: Hotkey? {
        get { shortcut(for: .assistant) }
        set { setShortcut(newValue, for: .assistant) }
    }

    /// Optional third shortcut for live-streaming dictation: transcribes as you
    /// speak and types the words straight into the focused field. nil = disabled.
    /// Persisted as JSON.
    var streamHotkey: Hotkey? {
        get { shortcut(for: .stream) }
        set { setShortcut(newValue, for: .stream) }
    }

    // MARK: Toggle bindings (tap to start, tap again to stop)

    /// Tap-to-toggle bind for one-shot dictation (nil = not set). Persisted JSON.
    var dictateToggleHotkey: Hotkey? {
        get { shortcut(for: .dictationToggle) }
        set { setShortcut(newValue, for: .dictationToggle) }
    }

    /// Tap-to-toggle bind for continuous dictation (nil = not set). Persisted JSON.
    var streamToggleHotkey: Hotkey? {
        get { shortcut(for: .streamToggle) }
        set { setShortcut(newValue, for: .streamToggle) }
    }

    /// The four on/off switches — one per config row (hold/toggle × modes).
    var dictateHoldOn: Bool {
        get { isEnabled(.dictation) }
        set { setEnabled(newValue, for: .dictation) }
    }
    var dictateToggleOn: Bool {
        get { isEnabled(.dictationToggle) }
        set { setEnabled(newValue, for: .dictationToggle) }
    }
    var streamHoldOn: Bool {
        get { isEnabled(.stream) }
        set { setEnabled(newValue, for: .stream) }
    }
    var streamToggleOn: Bool {
        get { isEnabled(.streamToggle) }
        set { setEnabled(newValue, for: .streamToggle) }
    }

    // MARK: Stored settings

    /// Non-secret assistant settings (provider, model, base URL, system prompt).
    /// API keys are stored separately in the Keychain. Persisted as JSON.
    @Stored("assistantConfig", default: .default) var assistantConfig: AssistantConfig

    /// Not a stored default: mirrors the real login-item state
    /// (`SMAppService`), read at launch.
    var launchAtLogin: Bool {
        willSet { objectWillChange.send() }
        didSet {
            guard !syncingLaunchAtLogin else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }
    /// True while a failed toggle snaps the switch back to the real state,
    /// so the revert doesn't re-run register()/unregister().
    private var syncingLaunchAtLogin = false

    /// When enabled, transcripts are inserted straight into the focused editable
    /// text field (when possible) instead of surfacing the copy box.
    /// Default TRUE: absent key means the user hasn't opted out yet.
    @Stored("autoInsert", default: true) var autoInsert: Bool

    /// Custom vocabulary — names, jargon, acronyms. Every dictation is
    /// spelling-corrected against it (`VocabularyCorrector`) and the
    /// ground-truth labeler is told to prefer these spellings.
    @Stored("hotwords", default: "") var hotwords: String

    /// A sentence of context that steers the transcription (optional).
    @Stored("contextPrompt", default: "") var contextPrompt: String

    /// How long you must hold the key before recording begins (seconds). Brief
    /// taps under this do nothing. Default 0.2s.
    @Stored("holdActivationDelay", default: 0) var holdActivationDelay: Double

    /// Opacity of the floating overlay chrome — the pill, transcribing dots, and
    /// answer box backgrounds. 1 = solid; lower = more see-through. Text stays
    /// fully opaque so answers remain readable. Default 0.92.
    @Stored("overlayOpacity", default: 0.4) var overlayOpacity: Double

    /// The pill stands upright on the right edge instead of bottom-centre.
    /// Text (results, the copy box, messages) always shows at the bottom.
    @Stored("pillOnRight", default: false) var pillOnRight: Bool

    /// WhisperKit model the on-device (Neural Engine) transcriber loads. Changing
    /// it reloads WhisperKit; the new model downloads once.
    /// Default to the bundled tiny model so the first launch works instantly
    /// and fully offline — the user can switch to a bigger one in Settings.
    @Stored("whisperModel", default: ModelCatalog.defaultDictation, emits: .dictationModel) var whisperModel: String

    /// WhisperKit model used by continuous (live streaming) dictation — fully
    /// independent of `whisperModel`. When set to the same name, the two share one
    /// resident instance; when different, both load. Changing it reloads its model.
    /// Continuous dictation defaults to the same bundled tiny model (so both
    /// sections share one instance until the user changes either one).
    @Stored("continuousModel", default: ModelCatalog.defaultContinuous, emits: .continuousModel)
    var continuousModel: String

    /// Characters-per-second the live typist eases the field toward during
    /// continuous dictation. `>= 120` means "Instant" (whole diff flushed at once).
    /// Default 30.
    @Stored("continuousTypeCPS", default: 80) var continuousTypeCPS: Double

    /// Developer-only: emit verbose diagnostic logs (filter "Slive." in Console /
    /// `log stream`). Off for normal users. Also forced on by `SLIVE_DEBUG=1`.
    @Stored("verboseLogging", default: false) var verboseLogging: Bool {
        didSet { applyLogGate() }
    }

    /// Offer a prefilled GitHub issue when Slive crashes, freezes or hits a
    /// failure (see FailureReporter). Nothing is sent unless the user submits
    /// it on GitHub. "Report a Problem…" works either way.
    @Stored("reportProblems", default: true) var reportProblems: Bool {
        didSet { FailureReporter.shared.settingsChanged() }
    }

    /// Developer/research: save each dictation's audio + transcript as training
    /// data. Off by default; stored locally only. See TrainingStore.
    @Stored("captureEdits", default: true) var captureEdits: Bool

    /// Hard cap on how much captured training data (audio + index) may occupy on
    /// disk, in gigabytes. When usage reaches this, capture stops until you free
    /// space or raise the limit. Default 1 GB.
    @Stored("captureMaxGB", default: 2.0) var captureMaxGB: Double

    /// Run the mic through the system voice-processing chain (the FaceTime echo
    /// canceller): what the Mac itself is playing over the speakers is
    /// subtracted from what the mic hears, so music/videos don't pollute the
    /// transcription in open-mic (no headphones) use. Default true. Applies from
    /// the next recording.
    /// Default FALSE (opt-in): the voice-processing chain audibly pops on
    /// some Macs when the device flips into voice-chat mode at recording
    /// start. Worth it when dictating over speaker audio; not as a default.
    @Stored("echoCancellation", default: false) var echoCancellation: Bool

    /// Core Audio UID of the microphone Slive listens on ("" = follow the
    /// system default input, the pre-picker behavior). Resolved to a live
    /// device at every recording start; an unplugged pick falls back to the
    /// default. Applies to one-shot AND continuous dictation.
    @Stored("inputDeviceUID", default: "") var inputDeviceUID: String
    /// Display name captured at pick time, so an unplugged mic is still
    /// named in the menu instead of showing a bare UID.
    @Stored("inputDeviceName", default: "") var inputDeviceName: String

    /// Which provider the Training section's ground-truth transcription uses.
    /// Only audio-capable providers are offered (Anthropic takes no audio).
    /// API keys come from the same Keychain slots the assistant uses.
    /// New installs default to OpenAI: the 3-way check (the default
    /// recipe) runs on an OpenAI key, so one key covers both recipes.
    @Stored("groundTruthProvider", default: .openai) var groundTruthProvider: AssistantProvider
    /// Model for ground-truth transcription (must accept audio input).
    /// Migrates the retired OpenAI audio id we once defaulted to — accounts
    /// without the legacy preview 404 on it; gpt-audio is the GA successor.
    @Stored(Setting(key: "groundTruthModel", defaultValue: "gpt-audio",
                    normalize: { $0 == "gpt-4o-audio-preview" ? "gpt-audio" : $0 }))
    var groundTruthModel: String
    /// Base URL when the ground-truth provider is OpenAI-compatible.
    @Stored("groundTruthBaseURL", default: "") var groundTruthBaseURL: String

    /// The user's edited base instruction for ground-truth transcription.
    /// Empty = follow the server's shipped default. The vocabulary tail is
    /// ALWAYS appended live server-side, whatever the base says.
    /// The consensus speaker line; empty = the default (label_consensus.py).
    @Stored("consensusPrompt", default: "") var consensusPrompt: String
    @Stored("groundTruthPrompt", default: "") var groundTruthPrompt: String

    /// How Should-be labels are made: the 3-way consensus (default — the
    /// measured best) or a single provider/model from the picker.
    @Stored("groundTruthRecipe", default: .consensus) var groundTruthRecipe: GroundTruthRecipe

    /// Local provider: load models int8-quantized (≈ half the RAM of bf16,
    /// near-identical output). Default on; applies from the next local ask
    /// (flipping it reloads the model).
    @Stored(Settings.localQuantizedSetting) var localQuantized: Bool
    /// Local provider: ceiling on a running model's memory, in GB. Models that
    /// can't plausibly fit are refused with a clear error before loading.
    @Stored(Settings.localMemLimitSetting) var localMemLimitGB: Double

    /// The latency ⇄ resources tier (SpeedTier raw value; 0 = Instant).
    /// Picked on the General page's tradeoff graph — each tier is a real set
    /// of residency/clock/warmup knobs, applied by TranscriptionModel and
    /// AppDelegate.
    @Stored("speedTier", default: SpeedTier.relaxed.rawValue) var speedTier: Int

    /// The typed tier, clamped safe against any stored value — an unknown one
    /// falls back to the fresh-install default, not the hungriest tier.
    var resolvedSpeedTier: SpeedTier { SpeedTier(rawValue: speedTier) ?? .relaxed }

    // MARK: Local inference (also read off the main actor)

    static let localQuantizedSetting = Setting(key: "localQuantized", defaultValue: true)
    static let localMemLimitSetting = Setting(
        key: "localMemLimitGB",
        defaultValue: localMemDefaultGB(ramGB: MachineProfile.ramGB),
        normalize: { min($0, localMemMaxGB(ramGB: MachineProfile.ramGB)) })

    /// Snapshot of the local-inference knobs, safe to read off the main actor —
    /// the HTTP clients build request bodies on background executors.
    nonisolated static func localInferenceOptions() -> (quantized: Bool, memGB: Double) {
        let d = UserDefaults.standard
        return (localQuantizedSetting.read(from: d), localMemLimitSetting.read(from: d))
    }

    /// Memory-limit default: 9 GB, but never past ~60% of this Mac's RAM — 9
    /// on an 8 GB Mac let a model load that swaps the machine to a crawl.
    nonisolated static func localMemDefaultGB(ramGB: Int) -> Double {
        guard ramGB > 0 else { return 9 }   // unreadable RAM: the old default
        return min(9, max(2, (Double(ramGB) * 0.6).rounded(.down)))
    }

    /// Memory-limit slider ceiling: 12 GB, leaving at least 2 GB for macOS.
    nonisolated static func localMemMaxGB(ramGB: Int) -> Double {
        guard ramGB > 0 else { return 12 }
        return min(12, max(3, Double(ramGB - 2)))
    }

    /// Ground truth: true once the event tap has actually delivered a keystroke.
    /// Proof that Input Monitoring is genuinely working, regardless of the
    /// cache-prone IOHIDCheckAccess API. Not persisted.
    var hotkeyActive = false {
        willSet { objectWillChange.send() }
    }

    // MARK: Defaults for a fresh install — Soumil's own setup (Nov 2026).

    /// A hotkey from its stored JSON, the same form Settings persists.
    private static func decodeHotkey(_ json: String) -> Hotkey? {
        try? JSONDecoder().decode(Hotkey.self, from: Data(json.utf8))
    }
    static let defaultDictateToggle = decodeHotkey(#"{"modifiers":262144,"taps":2,"label":"⌃ ×2"}"#)
    static let defaultAssistantHotkey = decodeHotkey(#"{"modifiers":8650752,"label":"⌃fn"}"#)
    /// Live typing stays off until asked for; the General page suggests these.
    static let suggestedStreamHotkey = decodeHotkey(#"{"taps":1,"keyCode":44,"modifiers":524288,"label":"⌥ /"}"#)
    static let suggestedStreamToggleHotkey = decodeHotkey(#"{"taps":1,"keyCode":47,"modifiers":524288,"label":"⌥ ."}"#)

    /// Every `@Stored` declaration, for loading and for the self-tests.
    var storedSettings: [AnyStoredSetting] {
        Mirror(reflecting: self).children.compactMap { $0.value as? AnyStoredSetting }
    }

    init(store: KeyValueStore = UserDefaults.standard) {
        self.store = store
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        for slot in ActionSpec.all.flatMap(\.slots) {
            guard let spec = slot.spec else { continue }
            shortcuts[slot] = .some(spec.readShortcut(from: store))
            // All switches default ON — a config only acts when its bind is
            // also set, so fresh installs behave exactly as before.
            if let key = spec.switchKey { switches[slot] = Bool.read(from: store, key: key) ?? true }
        }
        // Load every @Stored value now, once, before anything can read them
        // from another thread.
        for setting in storedSettings { setting.load(from: store) }
        // Apply the gate immediately (didSet doesn't fire from init).
        applyLogGate()
    }

    /// The env var can force verbose logs on regardless of the stored/UI setting.
    private func applyLogGate() {
        Log.enabled = verboseLogging || ProcessInfo.processInfo.environment["SLIVE_DEBUG"] == "1"
    }

    // MARK: - Assistant API keys (Keychain-backed)

    /// Read a provider's stored API key (nil/empty if none). Trimmed on read as
    /// well as write: a value stored by an earlier build (before `setAPIKey`
    /// trimmed) can still carry a trailing newline, which would otherwise reach
    /// the HTTP layer as an illegal `Authorization` header value.
    func apiKey(for provider: AssistantProvider) -> String {
        CredentialStore.shared.apiKey(for: provider)   // the Keychain's single owner
    }

    /// Store (or clear, when empty) a provider's API key. Trimmed so a stray
    /// newline/space (common when pasting) can't produce an illegal HTTP header.
    /// Also nudges observers so the settings UI reflects the change.
    func setAPIKey(_ key: String, for provider: AssistantProvider) {
        CredentialStore.shared.setAPIKey(key, for: provider)
        objectWillChange.send()
    }

    private static let didFirstRunKey = "didFirstRun"

    var isFirstRun: Bool {
        !store.bool(forKey: Self.didFirstRunKey)
    }

    func markFirstRunComplete() {
        store.set(true, forKey: Self.didFirstRunKey)
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
            // Otherwise the switch shows the new value while nothing changed.
            syncingLaunchAtLogin = true
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            syncingLaunchAtLogin = false
        }
    }
}

extension AssistantConfig: JSONSetting {}
extension AssistantProvider: StorableSetting {}
extension GroundTruthRecipe: StorableSetting {}

extension Bundle {
    /// "v0.2.4" — the bundle's real version (build.sh stamps it from VERSION),
    /// for the Settings footer. A bare `swift build` binary has no Info.plist.
    var versionLabel: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "dev"
    }
}
