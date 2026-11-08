import AppKit
import Combine
import Foundation

/// The user states the Settings render suite opens Settings in.
enum RenderState: String, CaseIterable {
    /// A brand-new install: every default (dictation on the bundled tiny.en,
    /// both suggestions showing), no keys, no permissions, nothing captured.
    case fresh
    /// Fresh, with both suggestions dismissed and every permission granted.
    case dismissed
    /// Soumil's setup: large-v3 dictation, Parakeet live typing, every
    /// shortcut set, the plain consensus recipe, keys, history, a populated
    /// Data table, a fine-tune installed, a finished training run.
    case configured
    /// Turbo and Parakeet downloading; a training run in progress.
    case downloading
    /// Turbo's download failed, Parakeet failed to load, a failed training
    /// run; only the mic granted.
    case failed
    /// base.en dictation with turbo already on disk (the suggestion hides
    /// itself on its first check).
    case turboOnDisk
}

/// One Settings environment built from fakes: in-memory settings and
/// secrets, the child's temp files (`RenderFiles`), fake speech engines,
/// fixed permissions and microphones, scripted server clients. Counts every
/// write and fetch so the suite can prove rendering had no side effects.
/// (Page-owned view models — the training job, the prompt editor — are
/// `@StateObject`s out of reach; their loops show as CPU and run-loop work.)
@MainActor
final class RenderWorld {
    let state: RenderState
    let env: SettingsEnv
    let settingsStore: CountingStore
    let secrets: CountingSecrets
    let engines: FakeEngines
    let trainingClient: ScriptedTrainingClient
    let promptClient: ScriptedPromptClient
    let customModels: FlappingRegistry

    /// Every ObservableObject the env provides, by name.
    var observed: [(String, ObservableObjectPublisher)] {
        [("Settings", env.settings.objectWillChange),
         ("PermissionsModel", env.permissions.objectWillChange),
         ("TranscriptionModel", env.transcription.objectWillChange),
         ("ProviderStore", env.providers.objectWillChange),
         ("TrainingStore", env.trainingStore.objectWillChange),
         ("LabelRun", env.labelRun.objectWillChange),
         ("HistoryStore", env.history.objectWillChange),
         ("SpeakingStats", env.stats.objectWillChange),
         ("InputDevices", env.inputDevices.objectWillChange),
         ("BackendManager", env.backend.objectWillChange),
         ("AssistantPromptLog", env.promptLog.objectWillChange),
         ("AudioPreviewPlayer", env.player.objectWillChange)]
    }

    init(_ state: RenderState, capabilities: Capabilities, files: RenderFiles, flappingRegistry: Bool = false) {
        self.state = state

        // Settings (in memory).
        settingsStore = CountingStore()
        let configured = state == .configured
        if configured {
            settingsStore.set(212.0, forKey: "wpm.last")
            settingsStore.set(176.0, forKey: "wpm.average")
            settingsStore.set(241.0, forKey: "wpm.best")
            settingsStore.set(58, forKey: "wpm.count")
        }
        let settings = Settings(store: settingsStore)
        switch state {
        case .fresh, .dismissed, .downloading, .failed: break
        case .configured:
            settings.whisperModel = WhisperCatalog.large
            settings.continuousModel = ParakeetModel.ultra.rawValue
            settings.streamHotkey = Settings.suggestedStreamHotkey
            settings.streamToggleHotkey = Settings.suggestedStreamToggleHotkey
            settings.assistantHotkey = Settings.defaultAssistantHotkey
            settings.groundTruthRecipe = .consensus
            settings.hotwords = "Slive\nParakeet\nWhisperKit"
            settings.contextPrompt = "Dictating code reviews."
            settings.verboseLogging = true
            settings.inputDeviceUID = RenderWorld.headset.uid
            settings.inputDeviceName = RenderWorld.headset.name
            settings.speedTier = SpeedTier.allCases.first?.rawValue ?? 0
            var config = settings.assistantConfig
            config.fetchedModels[AssistantProvider.openai.rawValue] = ["gpt-5.5", "gpt-5.5-mini", "gpt-audio"]
            settings.assistantConfig = config
        case .turboOnDisk:
            settings.whisperModel = WhisperCatalog.base
            settings.echoCancellation = true
        }

        // Keys (never the Keychain).
        secrets = CountingSecrets()
        if configured {
            secrets.values[CredentialStore.account(for: .openai)] = "sk-render-fixture"
            secrets.values[CredentialStore.account(for: .anthropic)] = "sk-ant-render-fixture"
            secrets.values[CredentialStore.hfAccount] = "hf_render_fixture"
        }
        let credentials = CredentialStore(secrets: secrets)
        let cache: [LocalCachedModel] = configured
            ? [LocalCachedModel(repo_id: "mlx-community/Qwen3-8B-4bit", size_bytes: 4_600_000_000, nb_files: 9),
               LocalCachedModel(repo_id: "openai/whisper-tokenizer", size_bytes: 2_000_000, nb_files: 3)]
            : []
        let providers = ProviderStore(settings: settings, credentials: credentials, scanLocalCache: { cache })

        // Speech: fake engines on a temp basket, fixture fine-tunes.
        var onDisk: Set<String> = [WhisperCatalog.tiny]   // bundled
        switch state {
        case .configured: onDisk.formUnion([WhisperCatalog.large, ParakeetModel.ultra.rawValue])
        case .turboOnDisk: onDisk.formUnion([WhisperCatalog.base, WhisperCatalog.turbo])
        default: break
        }
        engines = FakeEngines(onDisk: onDisk)
        let fineTune = configured || flappingRegistry ? files.fineTune : nil
        customModels = FlappingRegistry(models: fineTune.map { [$0] } ?? [], flaps: flappingRegistry)
        let engines = engines
        let registry = customModels
        let transcription = TranscriptionModel(
            basket: ModelBasket(root: files.basket),
            customModels: { registry.read() },
            policy: { ResidencyPolicy(pins: true, releasesUnderPressure: false,
                                      primesOnHold: false, warmsAfterLoad: false) },
            engines: { engines.parts(for: $0) })
        engines.owner = transcription
        switch state {
        case .downloading:
            transcription.setStatus(.downloading(0.42), for: WhisperCatalog.turbo)
            transcription.setStatus(.downloading(0.08), for: ParakeetModel.ultra.rawValue)
        case .failed:
            transcription.setStatus(.failed("Download failed: The Internet connection appears to be offline."),
                                    for: WhisperCatalog.turbo)
            transcription.setStatus(.failed("Parakeet load timed out."), for: ParakeetModel.ultra.rawValue)
        default: break
        }

        // Captured samples (a temp folder, never Application Support).
        let trainingRoot = configured || state == .downloading ? files.samples : files.emptyTraining
        let trainingStore = TrainingStore(root: trainingRoot, captureMaxGB: { settings.captureMaxGB })
        let labelRun = LabelRun(store: trainingStore, settings: settings, providers: providers)

        let history = HistoryStore(fileURL: nil)
        if configured {
            for text in RenderWorld.historyTexts { history.add(text) }
        }

        let grants: PermissionsModel.Grants
        switch state {
        case .fresh, .downloading: grants = .init(mic: false, inputMonitoring: false, accessibility: false)
        case .failed: grants = .init(mic: true, inputMonitoring: false, accessibility: false)
        case .dismissed, .configured, .turboOnDisk: grants = .init(mic: true, inputMonitoring: true, accessibility: true)
        }
        let permissions = PermissionsModel(hotkeyActive: { settings.hotkeyActive }, probe: { grants })

        let promptLog = AssistantPromptLog()
        if configured { promptLog.record(prompt: "You are Slive's assistant.", provider: "OpenAI", model: "gpt-5.5") }

        trainingClient = ScriptedTrainingClient(state)
        promptClient = ScriptedPromptClient()

        env = SettingsEnv(
            settings: settings,
            permissions: permissions,
            transcription: transcription,
            providers: providers,
            trainingStore: trainingStore,
            labelRun: labelRun,
            history: history,
            stats: SpeakingStats(store: settingsStore),
            inputDevices: InputDevices(devices: [RenderWorld.builtIn, RenderWorld.headset],
                                       systemDefault: RenderWorld.builtIn),
            backend: BackendManager(),
            promptLog: promptLog,
            player: AudioPreviewPlayer(),
            trainingClient: trainingClient,
            promptClient: promptClient,
            capabilities: capabilities,
            relaunch: {})
    }

    /// The two suggestions' dismissals live in `@AppStorage` (the standard
    /// defaults). Set them in the argument domain — in memory, searched
    /// first, never written to disk.
    func applyDefaults() {
        let dismissed = state == .dismissed || state == .configured
        var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        args["balancedSuggestionDismissed"] = dismissed
        args["liveTypingSuggestionDismissed"] = dismissed
        UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    }

    func tearDown() {
        env.permissions.stopWatching()
        env.player.stop()
    }

    // MARK: - Fixtures

    static let builtIn = InputDevices.Device(id: 91, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                             transport: "Built-in", sampleRate: 48_000)
    static let headset = InputDevices.Device(id: 92, uid: "00-1A-7D-DA-71-13:input", name: "HP H250",
                                             transport: "Bluetooth", sampleRate: 16_000)

    static let historyTexts = [
        "Ship the settings render check before the release.",
        "Parakeet keeps up when I talk fast, Whisper doesn't.",
        "Remind me to rerun the consensus labels tonight.",
        "The turbo suggestion froze a fresh install on November 13th.",
        "Open the Data page and listen to the flagged rows.",
        "Short one.",
    ]

    /// A fine-tune the registry accepts: manifest, the three model files and
    /// a local tokenizer.
    static func fineTune(in dir: URL) -> CustomWhisperModel? {
        let fm = FileManager.default
        let folder = dir.appendingPathComponent("Custom/soumil-turbo-ft", isDirectory: true)
        for part in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] {
            try? fm.createDirectory(at: folder.appendingPathComponent("model/\(part).mlmodelc"),
                                    withIntermediateDirectories: true)
        }
        let tokenizer = folder.appendingPathComponent("tokenizer/models/openai/whisper-large-v3-turbo")
        try? fm.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        fm.createFile(atPath: tokenizer.appendingPathComponent("tokenizer.json").path, contents: Data("{}".utf8))
        let manifest = #"{"id": "soumil-turbo-ft", "display_name": "Soumil · turbo fine-tune", "base_model": "large-v3-v20240930_626MB", "model_folder": "model", "tokenizer_folder": "tokenizer"}"#
        fm.createFile(atPath: folder.appendingPathComponent("manifest.json").path, contents: Data(manifest.utf8))
        return CustomWhisperModelRegistry.model(in: folder)
    }

    /// `count` samples covering every row the Data table draws: unlabeled,
    /// single-model, consensus (high, low agreement, unconfirmed words),
    /// formatted / rejected formats, human edits, way-off, missing audio.
    static func writeSamples(to root: URL, count: Int) {
        let fm = FileManager.default
        let audio = root.appendingPathComponent("audio", isDirectory: true)
        try? fm.createDirectory(at: audio, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines = Data()
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        for i in 0..<count {
            let id = String(format: "render-%03d", i)
            let hasAudio = i % 9 != 4
            if hasAudio {
                fm.createFile(atPath: audio.appendingPathComponent("\(id).wav").path,
                              contents: Data(repeating: 0, count: 3_200 + i * 64))
            }
            let typed = "the quick brown fox number \(i) jumps over the lazy dog"
            var sample = EditSample(
                id: id, createdAt: start.addingTimeInterval(Double(i) * 90), app: "com.apple.TextEdit",
                transcript: typed, finalText: "", edited: false, confidence: "high",
                audioFile: hasAudio ? "audio/\(id).wav" : nil,
                llmTranscript: nil, llmModel: nil, llmAgreement: nil, llmUnconfirmed: nil,
                llmFormatted: nil, llmFormatStatus: nil, llmFormatModel: nil)
            switch i % 7 {
            case 0: break                                            // unlabeled
            case 1:                                                  // one provider
                sample.llmTranscript = typed.replacingOccurrences(of: "fox", with: "fox,")
                sample.llmModel = "gpt-audio"
            case 2:                                                  // consensus, agreed
                sample.llmTranscript = typed.capitalized
                sample.llmModel = LabelScope.modelTag(chosen: "whisper-1")
                sample.llmAgreement = 0.97
            case 3:                                                  // consensus, worth a listen
                sample.llmTranscript = "the quick brown box number \(i) jumped over a lazy dog"
                sample.llmModel = LabelScope.modelTag(chosen: "gpt-transcribe")
                sample.llmAgreement = 0.62
                sample.llmUnconfirmed = ["box", "jumped"]
            case 4:                                                  // formatted
                sample.llmTranscript = typed
                sample.llmModel = LabelScope.modelTag(chosen: "whisper-1")
                sample.llmAgreement = 0.9
                sample.llmFormatted = "The quick brown fox (number \(i)) jumps over the lazy dog."
                sample.llmFormatStatus = "formatted"
                sample.llmFormatModel = "gpt-5.5"
            case 5:                                                  // human edit
                sample.finalText = "The quick brown fox #\(i) jumps over the lazy dog."
                sample.edited = true
            default:                                                 // way off + rejected format
                sample.llmTranscript = "completely different words were heard in this clip"
                sample.llmModel = LabelScope.modelTag(chosen: "whisper-1")
                sample.llmAgreement = 0.4
                sample.llmFormatted = "Completely different."
                sample.llmFormatStatus = "rejected:changed words"
                sample.llmFormatModel = "gpt-5.5"
            }
            if let line = try? encoder.encode(sample) {
                lines.append(line)
                lines.append(0x0A)
            }
        }
        fm.createFile(atPath: root.appendingPathComponent("samples.jsonl").path, contents: lines)
    }
}

/// The files every world in one child reads (never writes): a temp
/// folder with an empty basket, an empty and a populated training folder,
/// and a fine-tune. Removed when the child ends.
@MainActor
final class RenderFiles {
    let root: URL
    let basket: URL
    let emptyTraining: URL
    let samples: URL
    let fineTune: CustomWhisperModel?

    nonisolated static func prefix(_ pid: Int32) -> String { "slive-render-\(pid)-" }

    init() {
        let fm = FileManager.default
        root = fm.temporaryDirectory
            .appendingPathComponent(Self.prefix(getpid()) + UUID().uuidString.prefix(8), isDirectory: true)
        basket = root.appendingPathComponent("Models", isDirectory: true)
        emptyTraining = root.appendingPathComponent("training-empty", isDirectory: true)
        samples = root.appendingPathComponent("training", isDirectory: true)
        for dir in [basket, emptyTraining.appendingPathComponent("audio"), samples] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        RenderWorld.writeSamples(to: samples, count: 46)
        fineTune = RenderWorld.fineTune(in: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A child that died (a loop, a hang) never removed its folder.
    nonisolated static func removeLeftovers(of pid: Int32) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(prefix(pid)) {
            try? fm.removeItem(at: tmp.appendingPathComponent(name))
        }
    }
}

// MARK: - Fakes

/// `InMemoryStore`, counting writes.
final class CountingStore: KeyValueStore {
    private let base = InMemoryStore()
    private(set) var writes = 0
    func resetWrites() { writes = 0 }

    func object(forKey key: String) -> Any? { base.object(forKey: key) }
    func set(_ value: Any?, forKey key: String) { writes += 1; base.set(value, forKey: key) }
    func removeObject(forKey key: String) { writes += 1; base.removeObject(forKey: key) }
    func string(forKey key: String) -> String? { base.string(forKey: key) }
    func data(forKey key: String) -> Data? { base.data(forKey: key) }
    func bool(forKey key: String) -> Bool { base.bool(forKey: key) }
    func integer(forKey key: String) -> Int { base.integer(forKey: key) }
    func double(forKey key: String) -> Double { base.double(forKey: key) }
}

/// Secrets in memory, counting writes (the Keychain is never touched).
final class CountingSecrets: SecretStore {
    var values: [String: String] = [:]
    private(set) var writes = 0
    func get(_ account: String) -> String? { values[account] }
    @discardableResult func set(_ value: String?, for account: String) -> Bool {
        writes += 1
        values[account] = value?.isEmpty == false ? value : nil
        return true
    }
}

/// Installed fine-tunes. `flaps`: every read returns a different list —
/// the registry then republishes on every refresh, exactly like the
/// unconditional assignment `refreshCustomModels` made before 4df6e9f.
final class FlappingRegistry {
    let models: [CustomWhisperModel]
    let flaps: Bool
    private(set) var reads = 0
    init(models: [CustomWhisperModel], flaps: Bool) {
        self.models = models
        self.flaps = flaps
    }
    func read() -> [CustomWhisperModel] {
        reads += 1
        return flaps && reads % 2 == 0 ? [] : models
    }
}

/// Speech engines that never touch a real model: "on disk" is a set, a
/// fetch fails (and is counted), a load hands back a recognizer that
/// decodes nothing.
@MainActor
final class FakeEngines {
    var onDisk: Set<String>
    /// Whisper's storage re-reads the fine-tunes on every on-disk check
    /// (`WhisperStorage.hasFiles`); the fake does the same through this.
    weak var owner: TranscriptionModel?
    private(set) var fetches = 0
    private(set) var loads = 0
    private lazy var storage = Storage(self)

    init(onDisk: Set<String>) { self.onDisk = onDisk }

    func parts(for model: String) -> (storage: ModelStorage, loader: ModelLoader) {
        (storage, Loader(engines: self))
    }

    @MainActor
    final class Storage: ModelStorage {
        unowned let engines: FakeEngines
        init(_ engines: FakeEngines) { self.engines = engines }
        func hasFiles(_ id: String) -> Bool {
            if SpeechEngine.of(id).kind == .whisper { engines.owner?.refreshCustomModels() }
            return engines.onDisk.contains(id)
        }
        func isInstalledLocally(_ id: String) -> Bool { false }
        func fetch(_ id: String, progress: DownloadProgress) async throws -> URL? {
            engines.fetches += 1
            throw CocoaError(.userCancelled)
        }
        func remove(_ id: String) {}
    }

    struct Loader: ModelLoader {
        let engines: FakeEngines
        func plan(_ id: String) -> LoadPlan? {
            guard engines.onDisk.contains(id) else { return nil }
            engines.loads += 1
            return LoadPlan(
                firstStage: "Loading", detail: "render fixture",
                load: { _ in SilentRecognizer() }, interim: nil,
                copy: LoadFailureCopy(engine: "fake", timedOutStatus: "", timedOutReport: "", failedReport: ""))
        }
    }

    final class SilentRecognizer: Recognizer {
        func transcribe(_ samples: [Float]) async throws -> String { "" }
        func warmUpClip(bundled: [Float]?) -> [Float]? { nil }
    }
}

/// The Training page's server routes, scripted per state (counted).
final class ScriptedTrainingClient: TrainingJobClient {
    let state: RenderState
    private(set) var calls = 0
    init(_ state: RenderState) { self.state = state }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private var metricsJSON: String {
        (1...24).map { u in
            String(format: #"{"update": %d, "epoch": %d, "loss": %.3f, "kl": %.4f}"#,
                   u, u / 9 + 1, 2.4 / Double(u).squareRoot(), 0.002 * Double(u))
        }.joined(separator: ", ")
    }

    func readiness() async throws -> TrainingReadiness {
        calls += 1
        let ready = state == .configured
        return try decode(#"{"eligible_count": \#(ready ? 64 : 3), "required_samples": 50, "remaining_samples": \#(ready ? 0 : 47), "ready": \#(ready), "eligible_audio_minutes": \#(ready ? 12.5 : 0.4), "required_audio_minutes": 10}"#)
    }

    func latest() async throws -> WhisperTrainingJob? {
        calls += 1
        switch state {
        case .configured:
            return try decode(#"{"id": "job-done", "model_name": "soumil-turbo-ft", "state": "done", "stage": "installed", "message": "Installed", "progress": 1, "eligible_samples": 64, "required_samples": 50, "installed_model_dir": "/tmp/ft", "metrics": [\#(metricsJSON)], "total_updates": 24, "evaluation": {"clips": 12, "base_wer": 0.081, "tuned_wer": 0.052}}"#)
        case .downloading:
            return try decode(#"{"id": "job-run", "model_name": "soumil-turbo-ft", "state": "running", "stage": "training", "message": "Epoch 2 of 3", "progress": 0.46, "eligible_samples": 64, "required_samples": 50, "metrics": [\#(metricsJSON)], "total_updates": 60, "created_at": "2026-11-14T09:12:00.123456"}"#)
        case .failed:
            return try decode(#"{"id": "job-err", "model_name": "soumil-turbo-ft", "state": "error", "stage": "converting", "message": "", "progress": 0.8, "eligible_samples": 64, "required_samples": 50, "error": "Core ML conversion ran out of memory.", "failed_stage": "converting", "resumable": true, "metrics": [\#(metricsJSON)], "total_updates": 24}"#)
        default:
            return nil
        }
    }

    func models() async throws -> [WhisperTrainingModel] {
        calls += 1
        return try decode(#"[{"id": "large-v3-v20240930_626MB", "label": "Whisper – large-v3 turbo", "hf_model": "openai/whisper-large-v3-turbo", "family": "large-v3", "multilingual": true, "detail": "Recommended", "learning_rate": 0.0001, "lora_rank": 16, "kl_weight": 0.3, "lora_ram_gb": 9}, {"id": "small", "label": "Whisper – small", "hf_model": "openai/whisper-small", "family": "small", "multilingual": true, "detail": ""}]"#)
    }

    func start(sourceModel: String, method: String, name: String?, maxRamGB: Double) async throws -> WhisperTrainingJob {
        calls += 1
        throw SliveError.serverDown(nil)
    }

    func resume(id: String) async throws -> WhisperTrainingJob {
        calls += 1
        throw SliveError.serverDown(nil)
    }

    func status(id: String) async throws -> WhisperTrainingJob {
        calls += 1
        guard let job = try await latest() else { throw SliveError.serverDown(nil) }
        return job
    }
}

/// The ground-truth default prompt route.
final class ScriptedPromptClient: GroundTruthPromptClient {
    private(set) var calls = 0
    func defaultPrompt() async throws -> String {
        calls += 1
        return "Transcribe exactly what is said."
    }
}
