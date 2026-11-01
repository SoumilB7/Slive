import CoreAudio
import Foundation
import WhisperKit

/// The app's one door to on-device speech: whether models are downloaded,
/// downloading them with progress, loading them, keeping them resident, and
/// transcribing — dictation and live streaming. The UI reads its per-model
/// `statuses`; AppDelegate, ContinuousDictation, the Settings views, LabelRun
/// and the benches call it.
///
/// A facade over the parts that do the work, each testable on its own:
/// - `ModelCatalog` / `SpeechEngine` — which engine a persisted id belongs to
/// - `ModelStorage` per engine + `ModelDownloads` — files, markers, downloads
/// - `ModelLoader` per engine + `ModelLoads` — load, timeout, cooldown, CPU copy
/// - `ResidencyManager` (+ `ResidencyPolicy` from the speed tier) — what's in
///   memory, warm-ups, Feather's release under memory pressure
/// - `SpeechDecoder` + `DecodeMetricsStore` — decodes and calibration
/// - `LiveSession` — continuous dictation
/// It's the only part that reads Settings (the speed tier, the chosen mic).
///
/// Adding an engine: a `SpeechEngine.Kind` case and its catalog list
/// (Catalog/), a `ModelStorage`, a `ModelLoader` whose plan builds its
/// `Recognizer` (+ a `LiveSession` from `makeLiveSession` if it streams),
/// and one case in `engine(for:)`. The compiler points at every switch.
@MainActor
final class TranscriptionModel: ObservableObject, ModelStatusBoard {
    static let shared = TranscriptionModel()

    typealias Status = ModelStatus

    /// Per-model status, keyed by model id. Drives the UI (both sections read
    /// `status(for:)` for the model they're pointed at).
    @Published private(set) var statuses: [String: Status] = [:]
    /// Fine-tuned models installed by the Python pipeline.
    @Published private(set) var customModels: [CustomWhisperModel] = []
    /// Set once a Feather reload proved slow (a full Neural Engine recompile):
    /// Feather then stops releasing models, and the speed graph says why.
    /// Cleared when the user picks a tier again.
    @Published private(set) var featherKeepsModelsReason: String?

    // MARK: - Parts

    private let modelBasket = ModelBasket.standard
    private let residency = ResidencyManager(
        policy: { ResidencyPolicy(Settings.shared.resolvedSpeedTier) },
        warmUpAudio: { AudioClip.warmUp })
    private lazy var whisperStorage = WhisperStorage(basket: modelBasket) { [unowned self] refresh in
        if refresh { self.refreshCustomModels() }
        return self.customModels
    }
    private lazy var parakeetStorage = ParakeetStorage(basket: modelBasket)
    private lazy var downloads = ModelDownloads(basket: modelBasket, board: self)
    private lazy var loads = ModelLoads(residency: residency, board: self, report: .app) { [unowned self] in
        self.engine(for: $0).loader
    }
    private lazy var decoder = SpeechDecoder(residency: residency, metrics: .standard, report: .app)

    /// One engine's storage and loader.
    private struct EngineParts {
        let storage: ModelStorage
        let loader: ModelLoader
    }

    private func engine(for model: String) -> EngineParts {
        switch SpeechEngine.of(model).kind {
        case .whisper: return EngineParts(storage: whisperStorage, loader: WhisperLoader(storage: whisperStorage))
        case .parakeet: return EngineParts(storage: parakeetStorage, loader: ParakeetLoader(storage: parakeetStorage))
        }
    }

    private func storage(for model: String) -> ModelStorage { engine(for: model).storage }

    private init() {
        refreshCustomModels()
        residency.onKeepsModelsReasonChange = { [unowned self] in self.featherKeepsModelsReason = $0 }
        residency.isLiveRunning = { [unowned self] in self.live != nil }
    }

    // MARK: - Status

    /// Status for a given model (defaults to not-downloaded if we've never touched it).
    func status(for model: String) -> Status { statuses[model] ?? .notDownloaded }
    func setStatus(_ status: Status, for model: String) { statuses[model] = status }

    /// Whether `model` is loaded and ready to transcribe right now (streaming needs
    /// one already in memory — it can't wait on a first-time load).
    func isReady(_ model: String) -> Bool { residency.isResident(model) }

    /// Called on the main actor whenever a model finishes loading (download +
    /// Neural Engine compile + warm-up done) — AppDelegate switches over to it.
    var onModelReady: ((String) -> Void)? {
        get { loads.onModelReady }
        set { loads.onModelReady = newValue }
    }

    /// The model a dictation actually runs on: the one the user picked once
    /// it's resident; until then the previous pick (kept resident by
    /// AppDelegate for exactly this). Switching models never blocks
    /// dictating — the download and the ~1–2 min Neural Engine compile
    /// happen behind the model already in use.
    func servingModel(wanted: String, fallback: String?) -> String {
        Self.pickServing(wanted: wanted, fallback: fallback, isResident: { residency.isResident($0) })
    }

    nonisolated static func pickServing(wanted: String, fallback: String?,
                                        isResident: (String) -> Bool) -> String {
        if isResident(wanted) { return wanted }
        if let fallback, isResident(fallback) { return fallback }
        return wanted
    }

    func refreshCustomModels() {
        customModels = CustomWhisperModelRegistry.load()
    }

    // MARK: - Storage (one basket in the app's data dir)

    var basket: URL { modelBasket.url }

    /// One-time: move any prior ~/Documents/huggingface downloads into the basket.
    func migrateOldDownloadsIfNeeded() { modelBasket.migrateOldDownloads() }

    /// Available without a download — bundled OR on disk.
    func isDownloaded(_ model: String) -> Bool { downloads.isDownloaded(model, in: storage(for: model)) }

    nonisolated static func folderName(for model: String, among names: [String]) -> String? {
        WhisperStorage.folderName(for: model, among: names)
    }

    nonisolated static func whisperVariant(vocabSize: Int, dModel: Int) -> ModelVariant {
        WhisperStorage.whisperVariant(vocabSize: vocabSize, dModel: dModel)
    }

    // MARK: - Memory management

    /// Evict any loaded model NOT in `keep` (and never the live one), freeing its
    /// Core ML / Neural Engine resources and its status entry. Called when a
    /// section switches model so RAM only holds what's actually referenced.
    func retainModels(_ keep: Set<String>) {
        for key in residency.retain(keep, live: liveModel) {
            statuses.removeValue(forKey: key)
        }
    }

    /// Release ALL loaded models from memory. Called on quit: the OS reclaims the
    /// process's memory on exit regardless, but dropping the instances
    /// deterministically frees their Core ML / Neural Engine resources first, and
    /// abandons any in-flight background loads so nothing lingers.
    func shutdown() {
        stopLiveDictation()
        residency.removeAll()
        liveModel = nil
    }

    // MARK: - Live streaming dictation

    /// The running live session and the model it's on.
    private var live: LiveSession?
    private var liveModel: String?

    /// The stream's confirmed transcript + how many seconds of audio it covers,
    /// maintained by the live callback. Reset at session start; read at release
    /// by the stitched (tail-only) final pass for long holds.
    private(set) var liveConfirmedText: String = ""
    private(set) var liveConfirmedEndSeconds: Double = 0

    /// Start real-time transcription from the mic using `model` (which MUST already
    /// be loaded). `onUpdate` fires on the main actor as speech is recognised, with
    /// the full running transcript so far (confirmed + still-forming tail, already
    /// cleaned) and recent mic energy (0…~1). The caller types it into the field
    /// with in-place correction. Returns false if `model` isn't loaded. Runs until
    /// `stopLiveDictation()`.
    func startLiveDictation(
        model: String,
        onUpdate: @escaping @MainActor (_ transcript: String, _ energy: Float) -> Void,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> Bool {
        let context = LiveContext(
            model: model, mic: Self.chosenMic(), onUpdate: onUpdate, onFailure: onFailure,
            onConfirmed: { [weak self] text, endSeconds in
                self?.liveConfirmedText = text
                self?.liveConfirmedEndSeconds = endSeconds
            })
        guard let session = residency.recognizer(model)?.makeLiveSession(context) else { return false }
        stopLiveDictation()   // never run two at once
        guard session.start() else { return false }
        live = session
        liveModel = model
        liveConfirmedText = ""
        liveConfirmedEndSeconds = 0
        return true
    }

    /// The mic the user chose in Settings, resolved here (main) so the stream
    /// never touches Settings.
    private static func chosenMic() -> LiveMicInput {
        LiveMicInput(capture: .shared,
                     preferred: InputDevices.resolve(uid: Settings.shared.inputDeviceUID),
                     systemDefault: { InputDevices.defaultInputID() })
    }

    /// A copy of every sample captured so far this live session (16 kHz mono).
    /// `model` is passed explicitly (not read from `liveModel`) so it stays
    /// valid across `stopLiveDictation()`, which clears `liveModel`. Grab this
    /// BEFORE stopping to keep the trailing audio.
    func liveSamplesSnapshot(model: String) -> [Float] {
        if let live, liveModel == model { return live.snapshot() }
        return residency.recognizer(model)?.streamedSamples() ?? []
    }

    /// Stop the live stream (ends its mic capture + realtime loop).
    func stopLiveDictation() {
        guard let session = live else { return }
        live = nil
        liveModel = nil
        session.stop()
    }

    // Silence trim moved to `SilenceTrim` (the pipeline's audio stage);
    // these forward so existing callers and tests keep working.
    nonisolated static var trimSpeechGate: Float { SilenceTrim.speechGate }
    nonisolated static var trimEdgeFloor: Float { SilenceTrim.edgeFloor }
    nonisolated static var trimLeadPad: Int { SilenceTrim.leadPad }
    nonisolated static var trimTailPad: Int { SilenceTrim.tailPad }

    nonisolated static func trimSilence(_ samples: [Float]) -> ArraySlice<Float> {
        SilenceTrim.trim(samples)
    }

    nonisolated static func edgeThreshold(frameRMS: [Float]) -> Float {
        SilenceTrim.edgeThreshold(frameRMS: frameRMS)
    }

    /// Moved to `StreamHygiene` (the pipeline's cleanup stage); forwards.
    nonisolated static func cleanStreamText(_ text: String) -> String {
        StreamHygiene.clean(text)
    }

    // MARK: - Decoding

    /// Transcribe a raw sample array in full on resident `model` (see
    /// `SpeechDecoder`). `model` is explicit so this still works after
    /// `stopLiveDictation()`.
    func transcribeSamples(_ samples: [Float], model: String) async -> String? {
        await decoder.transcribe(samples, model: model)
    }

    /// Transcribe `url` strictly using `model`. If it isn't loaded yet, load
    /// it when it's available; returns nil otherwise (and kicks off a select) so the
    /// caller can tell the user what to do.
    func transcribe(_ url: URL, model: String) async -> String? {
        // Joins an in-flight load (never a duplicate) as a WAITING dictation,
        // so the load skips its warm-up instead of making this decode queue
        // behind it.
        guard await awaitReady(model) else { return nil }
        return await decoder.transcribe(fileAt: url, model: model)
    }

    nonisolated static func decodeTimeoutSeconds(audioSeconds: Double) -> UInt64 {
        SpeechDecoder.timeoutSeconds(audioSeconds: audioSeconds)
    }

    /// WhisperKit's decode options (see `WhisperRecognizer.decodeOptions`).
    func decodeOptions(chunking: Bool = false) -> DecodingOptions {
        WhisperRecognizer.decodeOptions(chunking: chunking)
    }

    // MARK: - Measured decode rate (calibration for the speed graph)

    nonisolated static func acceptableCalibrationClip(_ audioSeconds: Double) -> Bool {
        DecodeMetricsStore.acceptableCalibrationClip(audioSeconds)
    }

    nonisolated static func blendedRate(old: Double?, new: Double) -> Double {
        DecodeMetricsStore.blendedRate(old: old, new: new)
    }

    nonisolated static func measuredTypicalDecode(for model: String) -> Double? {
        DecodeMetricsStore.standard.typicalDecode(for: model)
    }

    // MARK: - Loading

    /// Load `model` if it isn't resident and wait for it. True when ready.
    func ensureLoaded(_ model: String, options: LoadOptions = .standard) async -> Bool {
        if !residency.isResident(model), isDownloaded(model) { await loads.loadShared(model, options: options) }
        return residency.isResident(model)
    }

    /// A dictation is waiting for `model` — join its load (or start it) and
    /// suppress the post-load warm-up (see `ModelLoads.awaitAsDictation`).
    /// True when ready.
    func awaitReady(_ model: String) async -> Bool {
        if residency.isResident(model) { return true }
        guard isDownloaded(model) else { select(model); return false }
        return await loads.awaitAsDictation(model)
    }

    nonisolated static var failedLoadCooldownSeconds: TimeInterval { ModelLoads.failedLoadCooldownSeconds }

    nonisolated static func inCooldown(failedAt: Date?, now: Date = Date()) -> Bool {
        ModelLoads.inCooldown(failedAt: failedAt, now: now)
    }

    /// `model` failed to load recently — don't start another load yet.
    func isCoolingDown(_ model: String) -> Bool { loads.isCoolingDown(model) }

    /// A dictation waiting on `model` will get it: it's loaded, loading, or
    /// downloaded with no recent failure (`awaitReady` starts the load).
    func canBecomeReady(_ model: String) -> Bool {
        residency.isResident(model) || loads.isRunning(model) || (isDownloaded(model) && !isCoolingDown(model))
    }

    nonisolated static var cpuCopyAfterSeconds: Double { WhisperLoader.cpuCopyAfterSeconds }

    nonisolated static func cpuCopyDelay(model: String, physicalMemory: UInt64) -> Double {
        WhisperLoader.cpuCopyDelay(model: model, physicalMemory: physicalMemory)
    }

    // MARK: - Warm-up + residency (speed vs battery)

    func warmUp(_ model: String) { residency.warmUp(model) }

    /// Bundled warm-up speech (Resources/WarmUp.wav, 16 kHz mono), or nil
    /// outside the app bundle.
    nonisolated static var warmUpAudio: [Float]? { AudioClip.warmUp }

    /// Called at hold-start: reload a released model (Feather) overlapped with
    /// the user speaking, or warm a cold one on tiers that prime
    /// (`ResidencyManager.primeIfCold`).
    func primeIfCold(_ model: String) {
        guard residency.primeIfCold(model) == .load, isDownloaded(model) else { return }
        Task { await loads.loadShared(model) }   // the load warms up on success
    }

    /// Apply the residency side of the selected SpeedTier
    /// (`ResidencyManager.applyPolicy`).
    func applySpeedTier(tierPicked: Bool = false) {
        residency.applyPolicy(tierPicked: tierPicked)
    }

    // MARK: - Selection / downloading

    /// Point at `model`: mark ready if already loaded, else load it in the
    /// background if it's available (never auto-downloads). An already-loaded model
    /// keeps working until this one is ready.
    func select(_ model: String) {
        refreshCustomModels()
        if residency.isResident(model) { statuses[model] = .ready; return }
        if residency.isLoading(model) { return }        // already preparing
        // A running download owns the status, and a failure stays on screen
        // (with its Re-download) until the user acts or the cooldown ends.
        switch status(for: model) {
        case .downloading: return
        case .failed where isCoolingDown(model) || !isDownloaded(model): return
        default: break
        }
        if isDownloaded(model) {
            // Mark it preparing NOW, not when the Task gets to run: callers
            // (AppDelegate's dictation-first ordering) read the status right
            // after this returns.
            statuses[model] = .preparing("Loading")
            Task { await loads.loadShared(model) }
        } else {
            statuses[model] = .notDownloaded
        }
    }

    /// A picker's status for `model` without loading it (a section that's
    /// switched off). Downloaded reads Ready, as for a Feather-released model
    /// — one hold away.
    func refreshStatus(_ model: String) {
        refreshCustomModels()
        if residency.isResident(model) { statuses[model] = .ready; return }
        switch status(for: model) {
        case .downloading, .preparing, .failed: return
        default: statuses[model] = isDownloaded(model) ? .ready : .notDownloaded
        }
    }

    /// Download (if needed) then load `model`, reporting progress.
    func download(_ model: String, options: LoadOptions = .standard) async {
        loads.clearFailure(model)   // asking again is an explicit retry
        refreshCustomModels()
        let storage = storage(for: model)
        if storage.isInstalledLocally(model) { await loads.loadShared(model, options: options); return }
        if residency.isResident(model) { statuses[model] = .ready; return }
        guard await downloads.fetch(model, into: storage) else { return }
        if !residency.isResident(model) { statuses[model] = .preparing("Loading") }
        await loads.loadShared(model, options: options)
    }

    /// Download `model` if it isn't on disk (no load). True when it is.
    func fetch(_ model: String) async -> Bool {
        await downloads.fetch(model, into: storage(for: model))
    }

    /// Delete the on-disk copy and fetch fresh (recovers a stale/partial download).
    func redownload(_ model: String) async {
        loads.clearFailure(model)
        let storage = storage(for: model)
        if storage.isInstalledLocally(model) { await loads.loadShared(model); return }
        // Never delete files under a download that's still running.
        if downloads.isRunning(model) { await download(model); return }
        // Let an in-flight load of this model finish first: deleting its
        // files under it and then JOINING it (download → loadShared) left
        // the stale load's outcome standing in for the fresh one. Bounded by
        // the load timeout.
        if let running = loads.task(model) { await running.value }
        residency.evict(model)
        storage.remove(model)
        await download(model)
    }
}
