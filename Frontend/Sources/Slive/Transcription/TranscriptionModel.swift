import AVFoundation
import CoreML
import Foundation
import WhisperKit

struct TimeoutError: Error {}
/// A download that made no progress for the watchdog's window.
private struct StallError: Error {}

/// Stamped by a download's progress callback (any thread); read by its
/// stall watchdog.
private final class ProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    func tick() { lock.lock(); last = Date(); lock.unlock() }
    var idleSeconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}

/// Set when a model load finishes (MainActor-only).
@MainActor private final class LoadFlag { var done = false }

/// Resumes a continuation exactly once, from whichever side finishes first.
private final class TimeoutRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    /// Resume the caller with `result` — true only for the first finisher.
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

/// Run `operation`, failing with `TimeoutError` if it doesn't finish in time.
///
/// Races an UNSTRUCTURED task against the timer. A task group can't do this:
/// it waits for every child before returning, and WhisperKit's `loadModels` /
/// FluidAudio's `AsrModels.load` ignore cancellation — so a hung Neural
/// Engine compile held the 600s "timeout" open forever (status stuck on
/// Preparing, every dictation waiting on the load never typed).
///
/// On timeout the operation is abandoned, not stopped (it can't be), and a
/// result that arrives later is DISCARDED: the app already reported the
/// failure, a retry may be under way, and Re-download may have deleted the
/// files it loaded. The retry is cheap by then — the compile it finished is
/// cached by the OS.
///
/// Decodes and warm-ups use it too: a Core ML predict that never returns
/// held `beginDecode` (and every dictation queued behind it) forever.
func withTimeout<T>(seconds: UInt64, what: String = "model load",
                    _ operation: @escaping () async throws -> T) async throws -> T {
    try await race(what: what, operation) { race in
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        if !Task.isCancelled { _ = race.finish(.failure(TimeoutError())) }
    }
}

/// Run a download, failing with `StallError` once `clock` hasn't ticked for
/// `seconds`. Neither HubApi nor FluidAudio can be cancelled mid-file and a
/// dead connection doesn't always error — Settings sat on "Downloading 37%"
/// forever. Same abandon-don't-stop race as `withTimeout`; a late finisher's
/// files are kept (the next download resumes from them).
private func withStallWatchdog<T>(seconds: TimeInterval, clock: ProgressClock,
                                  _ operation: @escaping () async throws -> T) async throws -> T {
    try await race(what: "download", operation) { race in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled, clock.idleSeconds > seconds { _ = race.finish(.failure(StallError())); return }
        }
    }
}

/// `operation` against `watchdog` (which fails the race when it fires); the
/// watchdog is cancelled once the operation finishes.
private func race<T>(what: String, _ operation: @escaping () async throws -> T,
                     watchdog: @escaping (TimeoutRace<T>) async -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let race = TimeoutRace(continuation)
        let timer = Task { await watchdog(race) }
        Task {
            do {
                let value = try await operation()
                timer.cancel()
                if !race.finish(.success(value)) {
                    Log.event("\(what) finished after its timeout — result discarded")
                }
            } catch {
                timer.cancel()
                _ = race.finish(.failure(error))
            }
        }
    }
}

/// Manages the on-device (WhisperKit) transcription models: checks whether they're
/// downloaded, downloads them in-app with progress, loads them, and transcribes.
///
/// Dictation and continuous (live streaming) dictation are fully independent, each
/// with its OWN model. This registry is therefore **keyed by model name**: it can
/// hold several WhisperKit instances at once, each with its own status. When both
/// sections point at the same model name, exactly ONE instance is resident (shared
/// by key); when they differ, two load side by side. `retainModels` evicts anything
/// no longer referenced so RAM never grows unbounded on a switch.
///
/// Inference runs on WhisperKit's default compute (Neural Engine) for the fastest
/// transcription. The ANE needs a slow one-time "specialize" compile per model —
/// so the loading is built to never freeze or stick on it:
/// - Loading runs in the **background** and an already-loaded model keeps serving
///   until the new one is ready — the app never freezes on a switch. The first load
///   of a model is the only slow one; it's cached after.
/// - A live per-model status (Downloading % / the WhisperKit load stage / Ready /
///   Failed) plus a hard timeout mean it never sits on a silent, stuck spinner.
@MainActor
final class TranscriptionModel: ObservableObject {
    static let shared = TranscriptionModel()
    private init() { refreshCustomModels() }

    enum Status: Equatable {
        case notDownloaded
        case downloading(Double)   // 0…1
        case preparing(String)     // WhisperKit load stage (e.g. "Loading")
        case ready
        case failed(String)
    }

    /// Per-model status, keyed by model name. Drives the UI (both sections read
    /// `status(for:)` for the model they're pointed at).
    @Published private(set) var statuses: [String: Status] = [:]
    /// Fine-tuned models installed by the Python pipeline.
    @Published private(set) var customModels: [CustomWhisperModel] = []
    /// Set once a Feather reload proved slow (a full Neural Engine recompile):
    /// Feather then stops releasing models, and the speed graph says why.
    /// Cleared when the user picks a tier again.
    @Published private(set) var featherKeepsModelsReason: String?

    /// Loaded WhisperKit instances, keyed by model name. One entry == one resident
    /// model in RAM.
    private var pipes: [String: WhisperKit] = [:]
    /// Loaded Parakeet models, keyed by model id (`parakeet-…`). Same
    /// lifecycle as `pipes`: one entry == one resident model.
    private var parakeets: [String: ParakeetEngine] = [:]

    /// Whether `model` is loaded in either engine.
    private func isResident(_ model: String) -> Bool {
        pipes[model] != nil || parakeets[model] != nil
    }
    /// Models being prepared in the background right now.
    private var loadingModels: Set<String> = []
    /// The one in-flight load per model. Everything that needs a model
    /// (selection, the hold-start prime, a dictation that arrives early)
    /// awaits THIS instead of starting its own — a duplicate load used to
    /// stall behind the first and lose the dictation.
    private var loadTasks: [String: Task<Void, Never>] = [:]

    // Live streaming dictation (separate path from file transcription). The live
    // model name selects which resident pipe the streaming helpers operate on.
    private var liveModel: String?
    private var liveTranscriber: AudioStreamTranscriber?
    /// The live session when the continuous model is a Parakeet model.
    private var parakeetLive: ParakeetLiveSession?

    /// Status for a given model (defaults to not-downloaded if we've never touched it).
    func status(for model: String) -> Status { statuses[model] ?? .notDownloaded }

    /// Whether `model` is loaded and ready to transcribe right now (streaming needs
    /// one already in memory — it can't wait on a first-time load).
    func isReady(_ model: String) -> Bool { isResident(model) }

    /// Called on the main actor whenever a model finishes loading (download +
    /// Neural Engine compile + warm-up done) — AppDelegate switches over to it.
    var onModelReady: ((String) -> Void)?

    /// The model a dictation actually runs on: the one the user picked once
    /// it's resident; until then the previous pick (kept resident by
    /// AppDelegate for exactly this). Switching models never blocks
    /// dictating — the download and the ~1–2 min Neural Engine compile
    /// happen behind the model already in use.
    func servingModel(wanted: String, fallback: String?) -> String {
        Self.pickServing(wanted: wanted, fallback: fallback, isResident: { isResident($0) })
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

    private func customModel(_ id: String) -> CustomWhisperModel? {
        customModels.first { $0.id == id }
    }

    // MARK: - Storage (one basket in the app's data dir)

    var basket: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Slive/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var modelsRoot: URL { basket.appendingPathComponent("models/argmaxinc/whisperkit-coreml") }

    /// One-time: move any prior ~/Documents/huggingface downloads into the basket.
    func migrateOldDownloadsIfNeeded() {
        let old = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models")
        let new = basket.appendingPathComponent("models")
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    // MARK: - Bundled model (ships in the app; offline)

    private func bundledModelFolder(_ model: String) -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let folder = res.appendingPathComponent("BundledModels/openai_whisper-\(model)")
        let ok = FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
        return ok ? folder : nil
    }
    private var bundledTokenizerRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("BundledTokenizers")
    }

    /// Available without a download — bundled OR on disk.
    func isDownloaded(_ model: String) -> Bool {
        // A download that hasn't finished (still running, stalled, or the app
        // quit mid-way) leaves its marker: its folder may already hold an
        // AudioEncoder, which once made a partial download look complete.
        if FileManager.default.fileExists(atPath: pendingMarker(model).path) { return false }
        if case .parakeet(let p) = SpeechEngine.of(model) {
            return ParakeetEngine.isDownloaded(p, basket: basket)
        }
        refreshCustomModels()
        if customModel(model) != nil { return true }
        if bundledModelFolder(model) != nil { return true }
        guard let folder = downloadedFolder(model) else { return false }
        // Downloads made before the completion marker existed count when
        // every model file and the tokenizer are on disk.
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.completeMarker).path)
            || isStructurallyComplete(folder)
    }

    /// Written into a model's folder once its download (+ tokenizer) finished.
    private static let completeMarker = ".slive-complete"

    /// Exists while `model`'s download is unfinished.
    private func pendingMarker(_ model: String) -> URL {
        basket.appendingPathComponent(".downloading-\(model)")
    }

    /// `model`'s folder in the basket, matched by exact name.
    private func downloadedFolder(_ model: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: modelsRoot.path)) ?? []
        return Self.folderName(for: model, among: names).map { modelsRoot.appendingPathComponent($0) }
    }

    /// WhisperKit names a variant's folder `openai_whisper-<variant>` (or
    /// `<org>_<variant>` for others). A suffix match once tied "large-v3" to
    /// distil-large-v3's folder too — so a partial one could pass for the
    /// other, and Re-download deleted both.
    nonisolated static func folderName(for model: String, among names: [String]) -> String? {
        if names.contains("openai_whisper-\(model)") { return "openai_whisper-\(model)" }
        if names.contains(model) { return model }
        let others = names.filter { $0.hasSuffix("_\(model)") }
        return others.count == 1 ? others[0] : nil
    }

    /// The three Core ML models WhisperKit can't load without.
    private static let requiredModels = ["AudioEncoder", "TextDecoder", "MelSpectrogram"]

    /// Every model file, config.json (in Hugging Face's path order it comes
    /// after the .mlmodelc folders, so it's among the last files fetched) and
    /// the tokenizer it names, which the load resolves locally.
    private func isStructurallyComplete(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard Self.requiredModels.allSatisfy({
            fm.fileExists(atPath: folder.appendingPathComponent("\($0).mlmodelc/coremldata.bin").path)
        }), let variant = Self.whisperVariant(configAt: folder) else { return false }
        return fm.fileExists(atPath: tokenizerFile(variant).path)
    }

    /// Where WhisperKit looks for `variant`'s tokenizer under the basket.
    private func tokenizerFile(_ variant: ModelVariant) -> URL {
        basket.appendingPathComponent("models/openai/whisper-\(variant.description)/tokenizer.json")
    }

    /// The variant (→ tokenizer) WhisperKit will detect for the model in
    /// `folder`, read from its config.json — nil when there is none.
    private nonisolated static func whisperVariant(configAt folder: URL) -> ModelVariant? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vocab = json["vocab_size"] as? Int, let width = json["d_model"] as? Int else { return nil }
        return whisperVariant(vocabSize: vocab, dModel: width)
    }

    /// WhisperKit's own detection (logits size × encoder width), mirrored so
    /// the download can fetch the tokenizer the load will ask for.
    nonisolated static func whisperVariant(vocabSize: Int, dModel: Int) -> ModelVariant {
        switch (vocabSize, dModel) {
        case (51866, _): return .largev3
        case (51865, 384): return .tiny
        case (51865, 768): return .small
        case (51865, 1024): return .medium
        case (51865, 1280): return .largev2
        case (51864, 384): return .tinyEn
        case (51864, 768): return .smallEn
        case (51864, 1024): return .mediumEn
        case (51864, _): return .baseEn
        default: return .base
        }
    }

    private func removeDownloaded(_ model: String) {
        if case .parakeet(let p) = SpeechEngine.of(model) {
            ParakeetEngine.remove(p, basket: basket); return
        }
        guard customModel(model) == nil, let folder = downloadedFolder(model) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Memory management

    /// Evict any loaded model NOT in `keep` (and never the live one), freeing its
    /// WhisperKit + Core ML / Neural Engine resources and its status entry. Called
    /// when a section switches model so RAM only holds what's actually referenced.
    func retainModels(_ keep: Set<String>) {
        for key in pipes.keys where !keep.contains(key) && key != liveModel {
            pipes.removeValue(forKey: key)
            statuses.removeValue(forKey: key)
            loadingModels.remove(key)
        }
        for key in parakeets.keys where !keep.contains(key) && key != liveModel {
            parakeets.removeValue(forKey: key)
            statuses.removeValue(forKey: key)
            loadingModels.remove(key)
        }
    }

    /// Release ALL loaded models from memory. Called on quit: the OS reclaims the
    /// process's memory on exit regardless, but dropping the WhisperKit instances
    /// deterministically frees their Core ML / Neural Engine resources first, and
    /// abandons any in-flight background loads so nothing lingers.
    func shutdown() {
        stopLiveDictation()
        pipes.removeAll()
        parakeets.removeAll()
        loadingModels.removeAll()
        liveModel = nil
    }

    // MARK: - Live streaming dictation

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
        if let engine = parakeets[model] {
            stopLiveDictation()   // never run two at once
            guard let device = InputDevices.resolve(uid: Settings.shared.inputDeviceUID)
                    ?? InputDevices.defaultInputID() else { return false }
            let session = ParakeetLiveSession(engine: engine) { text in
                onUpdate(StreamHygiene.clean(text), 0)
            }
            do { try session.start(device: device) } catch {
                Log.live("parakeet START failed — \(error.localizedDescription)")
                return false
            }
            liveModel = model
            liveConfirmedText = ""
            liveConfirmedEndSeconds = 0   // no stitched release: the final pass decodes all (~0.2s)
            parakeetLive = session
            Log.live("START model=\(model) (parakeet live loop)")
            return true
        }
        guard let pipe = pipes[model], let tokenizer = pipe.tokenizer else { return false }
        stopLiveDictation()   // never run two at once
        liveModel = model
        liveConfirmedText = ""
        liveConfirmedEndSeconds = 0
        // Fresh buffer per session — otherwise the shared audioProcessor would
        // still hold the previous utterance and re-transcribe it from the top.
        pipe.audioProcessor.purgeAudioSamples(keepingLast: 0)

        // Dedupe + instrumentation. The state callback also fires on every mic-
        // energy tick (~10×/s) with an UNCHANGED transcript; only push through real
        // text changes. The logs (filter "Slive.live") show, per hold: each text
        // growth with the gap since the last one + mic energy, an idle heartbeat
        // when text is frozen but audio is flowing (→ VAD skip / loop death), and
        // whether the stream loop ends before release (→ the loop died).
        var lastTranscript = ""
        var lastChange = Date()
        var lastBeat = Date()
        Log.live("START model=\(model)")

        // The chosen microphone rides in through a routing wrapper — the
        // transcriber opens the mic itself and would otherwise always take
        // the system default. Resolved here (main) so the stream task never
        // touches Settings.
        let routed = DeviceRoutedAudioProcessor(
            base: pipe.audioProcessor,
            preferredDevice: InputDevices.resolve(uid: Settings.shared.inputDeviceUID))

        let transcriber = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: routed,
            decodingOptions: decodeOptions(),
            // Confirm text after just one trailing segment (default is 2) so the
            // stable prefix grows sooner.
            requiredSegmentsForConfirmation: 1,
            // Push-to-talk: the user is deliberately speaking the whole time, so
            // don't let the voice-activity gate SKIP transcribe passes on quieter
            // stretches — that's what made live text "hang" mid-phrase and only
            // catch up on release. A low threshold still ignores dead silence but
            // no longer drops real (soft) speech.
            silenceThreshold: 0.1,
            useVAD: true,
            stateChangeCallback: { _, state in
                // Full transcript so far = confirmed prefix + still-forming tail.
                // (NOT state.currentText, which is the volatile decode and can be
                // an early hallucination or the "Waiting for speech..." placeholder.)
                let confirmed = state.confirmedSegments.map { $0.text }.joined()
                let tail = state.unconfirmedSegments.map { $0.text }.joined()
                let transcript = StreamHygiene.clean(confirmed + tail)
                let energy = state.bufferEnergy.last ?? 0
                let now = Date()
                guard transcript != lastTranscript else {   // energy-only tick
                    if now.timeIntervalSince(lastBeat) > 1.0 {
                        Log.live(String(format: "  …frozen %.1fs  energy=%.2f  conf=%d tail=%d",
                                        now.timeIntervalSince(lastChange), energy, confirmed.count, tail.count))
                        lastBeat = now
                    }
                    return
                }
                Log.live(String(format: "+text len=%d (+%d)  gap=%.2fs  energy=%.2f  conf=%d tail=%d  «%@»",
                                transcript.count, transcript.count - lastTranscript.count,
                                now.timeIntervalSince(lastChange), energy, confirmed.count, tail.count,
                                String(transcript.suffix(24))))
                lastChange = now
                lastBeat = now
                lastTranscript = transcript
                let confirmedEnd = Double(state.lastConfirmedSegmentEndSeconds)
                Task { @MainActor in
                    // Confirmed-progress snapshot for the stitched release decode:
                    // on a long hold, release re-decodes only [confirmedEnd-0.3s…]
                    // and stitches onto this text instead of the whole utterance.
                    self.liveConfirmedText = confirmed
                    self.liveConfirmedEndSeconds = confirmedEnd
                    onUpdate(transcript, 0)
                }
            }
        )
        liveTranscriber = transcriber
        Task {
            do {
                try await transcriber.startStreamTranscription()
                // Returns when the realtime loop ends. If this logs BEFORE the user
                // releases, the loop died on a decode error (streaming is dead until
                // release). Normally it logs right after stopLiveDictation().
                Log.live("stream loop ended")
            } catch where error is CancellationError || Task.isCancelled {
                Log.live("stream stopped")   // stopLiveDictation, not a failure
            } catch {
                // The mic failed to open: without this the pill kept
                // "listening" and nothing ever typed.
                Log.live("stream ERROR — \(error)")
                let ns = error as NSError
                Log.event("live stream failed to start (\(ns.domain) \(ns.code))")
                FailureReporter.shared.report("live typing", "Live typing couldn't start the microphone.", error: error)
                onFailure?()
            }
        }
        return true
    }

    /// A copy of every sample captured so far this live session (16 kHz mono), from
    /// `model`'s audioProcessor. `model` is passed explicitly (not read from
    /// `liveModel`) so it stays valid across `stopLiveDictation()`, which clears
    /// `liveModel`. Grab this BEFORE stopping to keep the trailing audio.
    /// The stream's confirmed transcript + how many seconds of audio it covers,
    /// maintained by the live callback. Reset at session start; read at release
    /// by the stitched (tail-only) final pass for long holds.
    private(set) var liveConfirmedText: String = ""
    private(set) var liveConfirmedEndSeconds: Double = 0

    func liveSamplesSnapshot(model: String) -> [Float] {
        if let session = parakeetLive, liveModel == model { return session.snapshot() }
        guard let pipe = pipes[model] else { return [] }
        return Array(pipe.audioProcessor.audioSamples)
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

    /// Transcribe a raw sample array in full on `model`'s pipe. Used on release to
    /// produce the complete, accurate transcript — including the final sub-second
    /// the streaming loop never processed (it only runs on >1s of new buffer).
    /// `model` is explicit so this still works after `stopLiveDictation()`.
    func transcribeSamples(_ samples: [Float], model: String) async -> String? {
        let limit = Self.decodeTimeoutSeconds(audioSeconds: Double(samples.count) / 16_000)
        if let engine = parakeets[model] {
            guard samples.count > 16_000 / 3 else { return nil }
            lastDecodeAt = Date()
            await beginDecode(model)
            defer { endDecode(model) }
            let t0 = Date()
            let text: String
            do {
                text = try await withTimeout(seconds: limit, what: "decode") {
                    try await engine.transcribe(samples)
                }
            } catch {
                Self.reportDecodeFailure(model, error)
                return nil
            }
            Self.recordDecode(model: model, audioSeconds: Double(samples.count) / 16_000,
                              decodeSeconds: Date().timeIntervalSince(t0))
            return text
        }
        guard let pipe = pipes[model], samples.count > 16_000 / 3 else { return nil }   // <~0.33s → skip
        lastDecodeAt = Date()
        await beginDecode(model)   // t0 after: the calibration measures this decode only
        defer { endDecode(model) }
        let t0 = Date()
        let options = decodeOptions(chunking: true)
        let results: [TranscriptionResult]
        do {
            results = try await withTimeout(seconds: limit, what: "decode") {
                try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            }
        } catch {
            Self.reportDecodeFailure(model, error)
            return nil
        }
        // Pure decode on a resident pipe — the only honest calibration source.
        Self.recordDecode(model: model,
                          audioSeconds: Double(samples.count) / 16_000,
                          decodeSeconds: Date().timeIntervalSince(t0))
        return StreamHygiene.clean(results.map { $0.text }.joined())
    }

    /// A decode that threw or never returned is a real fault (silence and
    /// too-short clips never get here) — offer a report.
    nonisolated static func reportDecodeFailure(_ model: String, _ error: Error) {
        if error is CancellationError { return }
        FailureReporter.shared.report("transcription",
                                      error is TimeoutError ? "A dictation's transcription never finished."
                                                            : "Transcribing a dictation failed.",
                                      error: error, detail: "model \(model)")
    }

    /// A decode that hasn't returned by now never will: 60s plus twice the
    /// audio covers a long hold on a CPU copy of large-v3. Past it the
    /// dictation reports a failure instead of holding the queue forever.
    nonisolated static func decodeTimeoutSeconds(audioSeconds: Double) -> UInt64 {
        60 + UInt64(max(0, audioSeconds) * 2)
    }

    /// Dev benchmarks set this to control warm-up themselves (never set by the app).
    static var benchSuppressesAutoWarm = false

    /// Load `model` if it isn't resident and wait for it. True when ready.
    func ensureLoaded(_ model: String) async -> Bool {
        if !isResident(model), isDownloaded(model) { await loadShared(model) }
        return isResident(model)
    }

    /// A dictation is waiting for `model` — join its load (or start it) and
    /// suppress the post-load warm-up: the waiting dictation IS the first
    /// decode, and a warm-up racing it on the same freshly compiled model is
    /// exactly what we don't want. True when ready.
    func awaitReady(_ model: String) async -> Bool {
        if isResident(model) { return true }
        guard isDownloaded(model) else { select(model); return false }
        dictationsWaiting[model, default: 0] += 1
        defer { dictationsWaiting[model, default: 1] -= 1 }
        // Start (or join) the load, but return the moment the model can serve:
        // a CPU copy can land long before a slow Neural Engine compile ends.
        let loading = LoadFlag()
        Task { await self.loadShared(model); loading.done = true }
        while !isResident(model), !loading.done {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isResident(model)
    }
    private var dictationsWaiting: [String: Int] = [:]

    /// When each model's last load failed (cleared on success or a
    /// Download / Re-download).
    private var failedLoadAt: [String: Date] = [:]
    /// After a failed load, holds don't start another for this long: each
    /// retry was a fresh up-to-600s wait, and a timed-out load can't be
    /// stopped — every hold stacked another one in RAM.
    nonisolated static let failedLoadCooldownSeconds: TimeInterval = 300

    nonisolated static func inCooldown(failedAt: Date?, now: Date = Date()) -> Bool {
        failedAt.map { now.timeIntervalSince($0) < failedLoadCooldownSeconds } ?? false
    }

    /// `model` failed to load recently — don't start another load yet.
    func isCoolingDown(_ model: String) -> Bool { Self.inCooldown(failedAt: failedLoadAt[model]) }

    /// A dictation waiting on `model` will get it: it's loaded, loading, or
    /// downloaded with no recent failure (`awaitReady` starts the load).
    func canBecomeReady(_ model: String) -> Bool {
        isResident(model) || loadTasks[model] != nil || (isDownloaded(model) && !isCoolingDown(model))
    }

    /// Start `model`'s load, or join the one already running.
    private func loadShared(_ model: String) async {
        if let running = loadTasks[model] { await running.value; return }
        guard !isCoolingDown(model) else { return }
        // The task clears its own entry before anyone it wakes runs, so no
        // waiter (e.g. `redownload`) can find and re-join a finished load.
        let task = Task {
            await self.load(model)
            self.loadTasks[model] = nil
        }
        loadTasks[model] = task
        await task.value
    }

    /// Decode options shared by every transcription path (file dictation, the live
    /// stream, and the final pass). `withoutTimestamps` matters for short clips:
    /// with timestamps on (WhisperKit's default) a <1s utterance often decodes to
    /// no content token at all — so quick dictations returned empty and nothing
    /// typed. `skipSpecialTokens` keeps `<|…|>` control tokens out of the text.
    ///
    /// Latency knobs (measured against the release→typed budget):
    /// - `temperatureFallbackCount` 5 → 1. Each fallback re-decodes the whole
    ///   window, and the trailing silence every dictation carries (release
    ///   tail + natural pauses) trips the logprob/compression thresholds
    ///   constantly — hundreds of ms of retries that essentially never change
    ///   the text. One retry keeps the safety net for genuine mis-decodes.
    /// - `chunking` (one-shot paths only): VAD-split >30s audio and decode the
    ///   chunks CONCURRENTLY instead of serial 30s windows — long dictations
    ///   release in roughly constant time. The live stream keeps linear
    ///   decoding: its confirmation logic is tuned to unchunked segments.
    func decodeOptions(chunking: Bool = false) -> DecodingOptions {
        var options = DecodingOptions(language: "en")
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.temperatureFallbackCount = 1
        if chunking {
            options.chunkingStrategy = .vad
        }
        return options
    }

    /// Moved to `StreamHygiene` (the pipeline's cleanup stage); forwards.
    nonisolated static func cleanStreamText(_ text: String) -> String {
        StreamHygiene.clean(text)
    }

    /// Stop the live stream (ends its mic capture + realtime loop).
    func stopLiveDictation() {
        if let session = parakeetLive {
            parakeetLive = nil
            liveModel = nil
            session.stop()
            Log.live("parakeet stream stopped after \(session.passes) passes")
            return
        }
        guard let t = liveTranscriber else { return }
        let model = liveModel
        liveTranscriber = nil
        liveModel = nil
        Task {
            // Await the stop FIRST: the stream actor's last in-flight decode
            // reads audioSamples, and purging concurrently would be a
            // cross-domain data race. Once it's confirmed stopped, free the
            // session's audio (64KB/s of Float32 — a long hold leaves tens of
            // MB) instead of holding it until the next session starts.
            await t.stopStreamTranscription()
            // Rapid re-hold guard: if a NEW live session has already started
            // (release → immediate re-press, the common gesture), it owns this
            // same audioProcessor and is filling the buffer right now — purging
            // here would wipe its session mid-stream. Only purge while nobody
            // owns the stream. (This Task runs on the main actor, so the check
            // can't race the setter in startLiveDictation.)
            guard liveTranscriber == nil, let model, let pipe = pipes[model] else { return }
            pipe.audioProcessor.purgeAudioSamples(keepingLast: 0)
        }
    }

    // MARK: - Measured decode rate (calibration for the speed graph)

    /// Rolling "seconds to decode a typical dictation", per model, persisted —
    /// the speed graph shows THIS machine's measured numbers instead of the
    /// static family guesses once a few dictations exist.
    ///
    /// Measured ONLY inside `transcribeSamples` (the pipe is already resident
    /// there, so model-load time can never leak in — the bug that once put
    /// "~15s" on the graph), and only from clips in the calibration band:
    /// long enough that fixed per-window overhead doesn't dominate, short
    /// enough to be one Whisper window like a real dictation.
    private nonisolated static let typicalDecodeKey = "typicalDecodeSeconds"

    /// Clips this long are honest one-window "typical dictation" samples.
    nonisolated static func acceptableCalibrationClip(_ audioSeconds: Double) -> Bool {
        (3...30).contains(audioSeconds)
    }

    /// EMA blend: measurements settle fast but one outlier can't lie.
    nonisolated static func blendedRate(old: Double?, new: Double) -> Double {
        old.map { $0 * 0.7 + new * 0.3 } ?? new
    }

    nonisolated static func measuredTypicalDecode(for model: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: typicalDecodeKey) as? [String: Double])?[model]
    }

    private nonisolated static func recordDecode(model: String, audioSeconds: Double,
                                                 decodeSeconds: Double) {
        guard acceptableCalibrationClip(audioSeconds),
              decodeSeconds > 0, decodeSeconds < 30 else { return }
        var values = (UserDefaults.standard.dictionary(forKey: typicalDecodeKey)
                      as? [String: Double]) ?? [:]
        values[model] = blendedRate(old: values[model], new: decodeSeconds)
        UserDefaults.standard.set(values, forKey: typicalDecodeKey)
    }

    // MARK: - Warmup + residency (speed vs battery)

    /// Last use of any model: stamped at the start of every decode, at hold
    /// start and when a load finishes. Drives the battery-mode idle unload
    /// and the cold-graph priming heuristic. (Stamping only decodes let
    /// Feather drop a model a minute after a 90s compile that followed a
    /// long idle, or between the hold-start reload and the release decode.)
    private var lastDecodeAt = Date()
    /// The in-flight warm-up per model — warming one model never skips
    /// warming another.
    private var warmUps: [String: Task<Void, Never>] = [:]
    /// Real decodes running per model (absent = none).
    private var decodesInFlight: [String: Int] = [:]
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// Models Feather released; the next load of one is timed as a reload.
    private var releasedByFeather: Set<String> = []
    /// A release must not land mid-session: the model has been idle this long.
    nonisolated static let pressureReleaseIdleSeconds: TimeInterval = 60
    /// A reload slower than this was a recompile, not a cache hit (~3s).
    nonisolated static let slowReloadSeconds: TimeInterval = 10

    /// Mark a real decode of `model` running, then wait out its in-flight
    /// warm-up: one WhisperKit instance isn't built for concurrent
    /// transcribes, and a warm-up sharing the pipe is the likely cause of
    /// "the first decode on a just-loaded model came back empty" (Oct 7).
    /// The wait is at most the warm-up already running; none starts while
    /// the decode is counted. Pair with `endDecode`.
    private func beginDecode(_ model: String) async {
        decodesInFlight[model, default: 0] += 1
        if let warming = warmUps[model] { await warming.value }
    }

    private func endDecode(_ model: String) {
        let left = decodesInFlight[model, default: 1] - 1
        decodesInFlight[model] = left > 0 ? left : nil
    }

    /// One real decode so the first dictation pays inference only. It must
    /// be SPEECH: 0.5s of silence (the old warm-up) is skipped by Whisper in
    /// ~10ms, leaving the first real dictation to pay ~1.3s of one-time setup
    /// (`--bench-coldstart`: first dictation 2.46s vs 1.15s warm; with a
    /// speech warm-up it's 1.18s). The bundled WarmUp.wav is 4.8s of macOS
    /// text-to-speech. Fire-and-forget; one at a time per model, and skipped
    /// while a real decode runs on it (that decode IS the warm-up).
    func warmUp(_ model: String) {
        guard warmUps[model] == nil, decodesInFlight[model] == nil else { return }
        if let engine = parakeets[model] {
            guard let audio = Self.warmUpAudio else { return }
            runWarmUp(model) { _ = try? await engine.transcribe(audio) }
            return
        }
        guard let pipe = pipes[model] else { return }
        let audio = Self.warmUpAudio ?? [Float](repeating: 0, count: 8_000)
        let options = decodeOptions()
        runWarmUp(model) { _ = try? await pipe.transcribe(audioArray: audio, decodeOptions: options) }
    }

    private func runWarmUp(_ model: String, _ decode: @escaping () async -> Void) {
        warmUps[model] = Task {
            let t0 = Date()
            // Bounded: a real decode waits on this (`beginDecode`).
            let done = (try? await withTimeout(seconds: 60, what: "warm-up", decode)) != nil
            warmUps[model] = nil
            Log.stt(String(format: "warm-up of %@ %@ after %.2fs", model,
                           done ? "done" : "TIMED OUT", Date().timeIntervalSince(t0)))
        }
    }

    /// Bundled warm-up speech (Resources/WarmUp.wav, 16 kHz mono), or nil
    /// outside the app bundle.
    static let warmUpAudio: [Float]? = {
        guard let url = Bundle.main.url(forResource: "WarmUp", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }()

    /// Called at hold-start: if the model was unloaded (Feather tier) start
    /// loading NOW — overlapped with the user speaking — and, on tiers that
    /// prime, if the graph has merely gone cold (minutes since the last
    /// decode), run a warmup in parallel with the hold so release pays
    /// inference only.
    func primeIfCold(_ model: String) {
        let idle = Date().timeIntervalSince(lastDecodeAt)
        // A hold is use: Feather must not drop the model between this
        // hold-start (re)load and the release decode. Also debounces repeat
        // holds while warming.
        lastDecodeAt = Date()
        if !isResident(model) {
            if isDownloaded(model) {
                Task { await loadShared(model) }   // load() warms up on success
            }
            return
        }
        guard Settings.shared.resolvedSpeedTier.primesOnHold, idle > 300 else { return }
        warmUp(model)
    }

    /// Apply the residency side of the selected SpeedTier. Pinned tiers just
    /// disarm the listener; Feather listens for macOS memory pressure and
    /// releases idle models when it comes — `primeIfCold` reloads on the next
    /// hold, overlapped with the user speaking, and the file path self-heals
    /// regardless. `tierPicked`: the user just chose a tier, so a previous
    /// "reloads are slow here" verdict is re-tested.
    func applySpeedTier(tierPicked: Bool = false) {
        if tierPicked { featherKeepsModelsReason = nil }
        guard Settings.shared.resolvedSpeedTier.releasesUnderPressure else {
            memoryPressure?.cancel()
            memoryPressure = nil
            return
        }
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .main)
        source.setEventHandler {
            Task { @MainActor in TranscriptionModel.shared.releaseUnderPressure() }
        }
        source.resume()
        memoryPressure = source
    }

    private func releaseUnderPressure() {
        guard Settings.shared.resolvedSpeedTier.releasesUnderPressure,
              featherKeepsModelsReason == nil,
              Date().timeIntervalSince(lastDecodeAt) > Self.pressureReleaseIdleSeconds,
              liveTranscriber == nil, parakeetLive == nil else { return }
        // Never pull a model out from under its own load, warm-up or decode.
        let busy = loadingModels.union(warmUps.keys).union(decodesInFlight.keys)
        let idle = Set(pipes.keys).union(parakeets.keys).subtracting(busy)
        guard !idle.isEmpty else { return }
        Log.event("Feather: memory pressure — released \(idle.sorted().joined(separator: ", "))")
        // Statuses stay .ready on purpose: the models are still downloaded and
        // one hold away — every decode path load-on-demands through
        // `primeIfCold` / `transcribe(url:)`.
        for key in idle {
            pipes.removeValue(forKey: key)
            parakeets.removeValue(forKey: key)
        }
        releasedByFeather.formUnion(idle)
    }

    /// A model finished loading in `seconds`. If Feather had released it and
    /// the reload was a recompile, stop releasing: on this Mac every release
    /// would cost that wait again.
    private func noteLoaded(_ model: String, seconds: Double) {
        guard releasedByFeather.remove(model) != nil, seconds > Self.slowReloadSeconds else { return }
        featherKeepsModelsReason = String(
            format: "Reloads are slow here (%.0f s), so models stay loaded.", seconds)
        Log.event(String(format: "Feather: reload of %@ took %.0fs — no longer releasing models", model, seconds))
    }

    // MARK: - Selection / loading

    /// Point at `model`: mark ready if already loaded, else load it in the
    /// background if it's available (never auto-downloads). An already-loaded model
    /// keeps working until this one is ready.
    func select(_ model: String) {
        refreshCustomModels()
        if isResident(model) { statuses[model] = .ready; return }
        if loadingModels.contains(model) { return }        // already preparing
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
            Task { await loadShared(model) }
        } else {
            statuses[model] = .notDownloaded
        }
    }

    /// A picker's status for `model` without loading it (a section that's
    /// switched off). Downloaded reads Ready, as for a Feather-released model
    /// — one hold away.
    func refreshStatus(_ model: String) {
        refreshCustomModels()
        if isResident(model) { statuses[model] = .ready; return }
        switch status(for: model) {
        case .downloading, .preparing, .failed: return
        default: statuses[model] = isDownloaded(model) ? .ready : .notDownloaded
        }
    }

    /// The one in-flight download per model: Turn on, Download and the
    /// continuous auto-fetch all join it instead of racing a second copy.
    private var downloadTasks: [String: Task<Bool, Never>] = [:]
    /// No progress for this long fails the download.
    nonisolated static let downloadStallSeconds: TimeInterval = 60

    /// Download (if needed) then load `model`, reporting progress.
    func download(_ model: String) async {
        failedLoadAt[model] = nil   // asking again is an explicit retry
        refreshCustomModels()
        if customModel(model) != nil { await loadShared(model); return }
        if isResident(model) { statuses[model] = .ready; return }
        guard await fetch(model) else { return }
        if !isResident(model) { statuses[model] = .preparing("Loading") }
        await loadShared(model)
    }

    /// Download `model` if it isn't on disk (no load). True when it is.
    func fetch(_ model: String) async -> Bool {
        if let running = downloadTasks[model] { return await running.value }
        if isDownloaded(model) { return true }
        statuses[model] = .downloading(0)
        let task = Task { () -> Bool in
            let ok = await self.performDownload(model)
            self.downloadTasks[model] = nil
            return ok
        }
        downloadTasks[model] = task
        return await task.value
    }

    private func performDownload(_ model: String) async -> Bool {
        let pending = pendingMarker(model)
        FileManager.default.createFile(atPath: pending.path, contents: nil)
        let clock = ProgressClock()
        // A late progress tick must not drag a failed or loading model back
        // to "Downloading".
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            clock.tick()
            Task { @MainActor in
                guard let self, case .downloading = self.statuses[model] else { return }
                self.statuses[model] = .downloading(fraction)
            }
        }
        do {
            if case .parakeet(let p) = SpeechEngine.of(model) {
                try await withStallWatchdog(seconds: Self.downloadStallSeconds, clock: clock) { [basket] in
                    try await ParakeetEngine.download(p, basket: basket, progress: report)
                }
            } else {
                let basket = self.basket
                let folder = try await withStallWatchdog(seconds: Self.downloadStallSeconds, clock: clock) {
                    let folder = try await WhisperKit.download(variant: model, downloadBase: basket) {
                        report($0.fractionCompleted)
                    }
                    // The tokenizer too: the load resolves it locally, so a
                    // downloaded model then loads with no network at all.
                    clock.tick()
                    if let variant = Self.whisperVariant(configAt: folder) {
                        _ = try await loadTokenizer(for: variant, tokenizerFolder: basket)
                    }
                    return folder
                }
                FileManager.default.createFile(
                    atPath: folder.appendingPathComponent(Self.completeMarker).path, contents: nil)
            }
            try? FileManager.default.removeItem(at: pending)
            statuses[model] = .ready   // on disk, one select away (see `refreshStatus`)
            return true
        } catch is StallError {
            Log.event("download of \(model) stalled — no progress for \(Int(Self.downloadStallSeconds))s")
            statuses[model] = .failed("Download stalled. Check your connection.")
        } catch {
            statuses[model] = .failed("Download failed: \(error.localizedDescription)")
        }
        return false
    }

    /// Delete the on-disk copy and fetch fresh (recovers a stale/partial download).
    func redownload(_ model: String) async {
        failedLoadAt[model] = nil
        if customModel(model) != nil { await loadShared(model); return }
        // Never delete files under a download that's still running.
        if downloadTasks[model] != nil { await download(model); return }
        // Let an in-flight load of this model finish first: deleting its
        // files under it and then JOINING it (download → loadShared) left
        // the stale load's outcome standing in for the fresh one. Bounded by
        // the load timeout.
        if let running = loadTasks[model] { await running.value }
        pipes.removeValue(forKey: model)
        parakeets.removeValue(forKey: model)
        removeDownloaded(model)
        await download(model)
    }

    /// Load a downloaded/bundled model in the background (Neural Engine, with a live
    /// stage + timeout). Swaps it in as a resident model only when it's fully ready,
    /// so anything already loaded keeps serving meanwhile.
    private func load(_ model: String) async {
        if case .parakeet(let p) = SpeechEngine.of(model) {
            await loadParakeet(p, id: model)
            return
        }
        loadingModels.insert(model)
        statuses[model] = .preparing("Loading")
        Log.stt("load begin \(model) (bundled=\(bundledModelFolder(model) != nil))")
        let t0 = Date()

        let bundled = bundledModelFolder(model)
        let custom = customModel(model)
        let tokenizerRoot = custom?.tokenizerFolder ?? (bundled != nil ? bundledTokenizerRoot : basket)
        // A downloaded model loads from its folder with downloads off. With
        // download: true WhisperKit asked Hugging Face for the file list on
        // EVERY load — offline, a downloaded model failed to load at all.
        let downloaded = custom == nil && bundled == nil ? downloadedFolder(model) : nil
        if custom == nil, bundled == nil, downloaded == nil {
            loadingModels.remove(model)
            statuses[model] = .notDownloaded
            return
        }
        // Encoder + decoder on the Neural Engine (fastest — `--bench-compute`:
        // GPU/CPU are ~3× slower per token). The mel spectrogram on the CPU:
        // WhisperKit's default puts it on the GPU, whose compiled MPSGraph
        // cache entry stops loading whenever a different Slive binary has
        // touched the shared cache ("Unable to load MPSGraphExecutable") —
        // every rebuild/reinstall then recompiled it for ~1–2 minutes before
        // ANY dictation could run. On CPU: load 100.6s → 10.8s on a fresh
        // binary, and the stage itself is faster (4ms vs 16ms per clip).
        func makeConfig(_ compute: ModelComputeOptions) -> WhisperKitConfig {
            if let custom {
                return WhisperKitConfig(model: model, modelFolder: custom.modelFolder.path,
                                          tokenizerFolder: tokenizerRoot, computeOptions: compute,
                                          prewarm: false, load: false, download: false)
            } else if let bundled {
                return WhisperKitConfig(model: model, modelFolder: bundled.path,
                                          tokenizerFolder: tokenizerRoot, computeOptions: compute,
                                          prewarm: false, load: false, download: false)
            } else {
                return WhisperKitConfig(model: model, modelFolder: downloaded?.path,
                                          tokenizerFolder: tokenizerRoot, computeOptions: compute,
                                          prewarm: false, load: false, download: false)
            }
        }
        let config = makeConfig(ModelComputeOptions(melCompute: .cpuOnly))

        // A slow Neural Engine compile (memory pressure, a busy compiler —
        // Nov 5: a fresh install sat on "Loading…" ~20 min) shouldn't block
        // dictation: after a grace period, load a CPU copy (no compile, ready
        // in seconds) and serve from it; the Neural Engine copy replaces it.
        let cpuCopyAfter = Self.cpuCopyDelay(model: custom?.baseModel ?? model,
                                             physicalMemory: ProcessInfo.processInfo.physicalMemory)
        let cpuCopy = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cpuCopyAfter * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.loadCPUCopy(model, config: makeConfig(ModelComputeOptions(
                melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly,
                textDecoderCompute: .cpuOnly, prefillCompute: .cpuOnly)), since: t0)
        }
        defer { cpuCopy.cancel() }

        do {
            // 600s: a cold Neural Engine compile after a macOS update or a
            // purged cache measured ~145s twice (Sep 29, Oct 7) — 150s was a
            // coin flip, and a timeout leaves the model failed.
            let p = try await withTimeout(seconds: 600) { [weak self] in
                let kit = try await WhisperKit(config)           // setup only — fast
                kit.modelStateCallback = { _, new in
                    Task { @MainActor in
                        guard let self, self.loadingModels.contains(model),
                              self.pipes[model] == nil else { return }   // a CPU copy is serving
                        self.statuses[model] = .preparing(new.description)  // live stage
                        Log.stt("stage \(model): \(new.description)")
                    }
                }
                // Test hook: a Neural Engine load that never finishes (the
                // Nov 5 fresh-install hang) — the CPU copy must still serve.
                if ProcessInfo.processInfo.environment["SLIVE_TEST_ANE_HANG"] == "1" {
                    try await Task.sleep(nanoseconds: 3_600_000_000_000)
                }
                try await kit.loadModels()                        // Neural Engine load — the work
                return kit
            }
            let replacedCPUCopy = pipes[model] != nil
            pipes[model] = p
            loadingModels.remove(model)
            failedLoadAt[model] = nil
            if replacedCPUCopy { Log.event("\(model): Neural Engine copy ready — replaced the CPU copy") }
            lastDecodeAt = Date()   // a fresh load is use — Feather keeps it its full window
            noteLoaded(model, seconds: Date().timeIntervalSince(t0))
            statuses[model] = .ready
            onModelReady?(model)
            Log.stt(String(format: "READY \(model) in %.1fs (resident: \(pipes.keys.sorted()))", Date().timeIntervalSince(t0)))
            Log.event(String(format: "model ready: %@ in %.1fs%@", model, Date().timeIntervalSince(t0),
                             dictationsWaiting[model, default: 0] > 0 ? " (a dictation is waiting)" : ""))
            // Immediately push the compiled graph through one tiny decode so
            // the FIRST real dictation pays inference only, not residency
            // (skipped on the Feather tier — its ethos is no idle spend).
            if Settings.shared.resolvedSpeedTier.warmsAfterLoad, !Self.benchSuppressesAutoWarm,
               dictationsWaiting[model, default: 0] == 0 { warmUp(model) }
        } catch is TimeoutError {
            loadingModels.remove(model)
            if pipes[model] != nil {
                Log.event("\(model): Neural Engine load timed out — staying on the CPU copy")
                statuses[model] = .ready
                return
            }
            Log.event("model load TIMED OUT: \(model)")
            failedLoadAt[model] = Date()
            statuses[model] = .failed("Timed out. Re-download or pick smaller.")
            FailureReporter.shared.report("speech model", "The speech model didn't finish loading in 10 minutes.",
                                          detail: "model \(model)")
            Log.stt("TIMEOUT loading \(model)")
        } catch {
            loadingModels.remove(model)
            if pipes[model] != nil {
                Log.event("\(model): Neural Engine load failed — staying on the CPU copy")
                statuses[model] = .ready
                return
            }
            failedLoadAt[model] = Date()
            statuses[model] = .failed(error.localizedDescription)
            Log.stt("FAILED loading \(model) — \(error)")
            NSLog("Slive: WhisperKit load failed — \(error)")
            FailureReporter.shared.report("speech model", "The speech model failed to load.",
                                          error: error, detail: "model \(model)")
        }
    }

    /// Seconds a Neural Engine load may take before a CPU copy is loaded to
    /// serve meanwhile. A cached load takes ~1–3s and a cold tiny.en ~10s; a
    /// healthy cold large-v3 turbo compile (~80s) gets the CPU copy too.
    nonisolated static var cpuCopyAfterSeconds: Double {
        ProcessInfo.processInfo.environment["SLIVE_CPU_COPY_AFTER"].flatMap(Double.init) ?? 20
    }

    /// A CPU copy sits in RAM beside the Neural Engine one while it compiles.
    /// For a large model on an 8 GB Mac that's ~1.5 GB more on top — swap,
    /// and both loads slow down — so there it waits longer for the Neural
    /// Engine (a normal cold compile is ~2 min). Never skipped: a compile
    /// that hangs must still end in a working model, not a 10-minute failure.
    nonisolated static func cpuCopyDelay(model: String, physicalMemory: UInt64) -> Double {
        model.contains("large") && physicalMemory <= 8 << 30 ? max(cpuCopyAfterSeconds, 150) : cpuCopyAfterSeconds
    }

    /// Load `model` CPU-only and serve from it while its Neural Engine load is
    /// still compiling. Dropped if the Neural Engine copy lands first.
    private func loadCPUCopy(_ model: String, config: WhisperKitConfig, since t0: Date) async {
        guard loadingModels.contains(model), pipes[model] == nil else { return }
        Log.event("\(model): Neural Engine still compiling — loading a CPU copy meanwhile")
        guard let kit = try? await WhisperKit(config), (try? await kit.loadModels()) != nil,
              loadingModels.contains(model), pipes[model] == nil else { return }
        pipes[model] = kit
        statuses[model] = .ready
        onModelReady?(model)
        Log.event(String(format: "model ready on CPU: %@ in %.1fs (Neural Engine still compiling)",
                         model, Date().timeIntervalSince(t0)))
    }

    /// Parakeet's load: compile + load onto the Neural Engine from Slive's
    /// basket, then the same ready/serving/warm-up path as Whisper.
    private func loadParakeet(_ p: ParakeetModel, id model: String) async {
        loadingModels.insert(model)
        statuses[model] = .preparing("Compiling")
        let t0 = Date()
        do {
            let engine = try await withTimeout(seconds: 600) { [basket] in
                try await ParakeetEngine.load(p, basket: basket)
            }
            parakeets[model] = engine
            loadingModels.remove(model)
            failedLoadAt[model] = nil
            lastDecodeAt = Date()
            noteLoaded(model, seconds: Date().timeIntervalSince(t0))
            statuses[model] = .ready
            onModelReady?(model)
            Log.event(String(format: "model ready: %@ in %.1fs", model, Date().timeIntervalSince(t0)))
            if Settings.shared.resolvedSpeedTier.warmsAfterLoad, !Self.benchSuppressesAutoWarm,
               dictationsWaiting[model, default: 0] == 0 { warmUp(model) }
        } catch is TimeoutError {
            loadingModels.remove(model)
            failedLoadAt[model] = Date()
            statuses[model] = .failed("Timed out. Re-download.")
            FailureReporter.shared.report("speech model", "The Parakeet model didn't finish loading.",
                                          detail: "model \(model)")
        } catch {
            loadingModels.remove(model)
            failedLoadAt[model] = Date()
            statuses[model] = .failed(error.localizedDescription)
            NSLog("Slive: Parakeet load failed — \(error)")
            FailureReporter.shared.report("speech model", "The Parakeet model failed to load.",
                                          error: error, detail: "model \(model)")
        }
    }

    /// Transcribe `url` strictly using `model`'s pipe. If it isn't loaded yet, load
    /// it when it's available; returns nil otherwise (and kicks off a select) so the
    /// caller can tell the user what to do.
    func transcribe(_ url: URL, model: String) async -> String? {
        // Joins an in-flight load (never a duplicate) as a WAITING dictation,
        // so the load skips its warm-up instead of making this decode queue
        // behind it.
        guard await awaitReady(model) else { return nil }
        if parakeets[model] != nil {
            guard let file = try? AVAudioFile(forReading: url),
                  file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil,
                  let channel = buffer.floatChannelData else { return nil }
            let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
            return await transcribeSamples(samples, model: model)
        }
        guard let pipe = pipes[model] else { return nil }
        lastDecodeAt = Date()
        await beginDecode(model)
        defer { endDecode(model) }
        let seconds = (try? AVAudioFile(forReading: url)).map {
            Double($0.length) / max(1, $0.processingFormat.sampleRate)
        } ?? 300
        let options = decodeOptions(chunking: true)
        do {
            let results = try await withTimeout(
                seconds: Self.decodeTimeoutSeconds(audioSeconds: seconds), what: "decode") {
                try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
            }
            return results
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("Slive: transcription failed — \(error)")
            Self.reportDecodeFailure(model, error)
            return nil
        }
    }
}
