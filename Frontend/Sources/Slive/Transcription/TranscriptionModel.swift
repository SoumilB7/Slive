import CoreML
import Foundation
import WhisperKit

private struct TimeoutError: Error {}

/// Run `operation`, failing with `TimeoutError` if it doesn't finish in time.
private func withTimeout<T>(seconds: UInt64,
                            _ operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw TimeoutError()
        }
        guard let result = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return result
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
    private init() {}

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

    /// Loaded WhisperKit instances, keyed by model name. One entry == one resident
    /// model in RAM.
    private var pipes: [String: WhisperKit] = [:]
    /// Models being prepared in the background right now.
    private var loadingModels: Set<String> = []

    // Live streaming dictation (separate path from file transcription). The live
    // model name selects which resident pipe the streaming helpers operate on.
    private var liveModel: String?
    private var liveTranscriber: AudioStreamTranscriber?

    /// Status for a given model (defaults to not-downloaded if we've never touched it).
    func status(for model: String) -> Status { statuses[model] ?? .notDownloaded }

    /// Whether `model` is loaded and ready to transcribe right now (streaming needs
    /// one already in memory — it can't wait on a first-time load).
    func isReady(_ model: String) -> Bool { pipes[model] != nil }

    // MARK: - Storage (one basket in the app's data dir)

    private var basket: URL {
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
        if bundledModelFolder(model) != nil { return true }
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: modelsRoot, includingPropertiesForKeys: nil) else { return false }
        return subs.contains { f in
            f.lastPathComponent.hasSuffix(model)
                && FileManager.default.fileExists(atPath: f.appendingPathComponent("AudioEncoder.mlmodelc").path)
        }
    }

    private func removeDownloaded(_ model: String) {
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: modelsRoot, includingPropertiesForKeys: nil) else { return }
        for f in subs where f.lastPathComponent.hasSuffix(model) { try? FileManager.default.removeItem(at: f) }
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
    }

    /// Release ALL loaded models from memory. Called on quit: the OS reclaims the
    /// process's memory on exit regardless, but dropping the WhisperKit instances
    /// deterministically frees their Core ML / Neural Engine resources first, and
    /// abandons any in-flight background loads so nothing lingers.
    func shutdown() {
        stopLiveDictation()
        pipes.removeAll()
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
        onUpdate: @escaping @MainActor (_ transcript: String, _ energy: Float) -> Void
    ) -> Bool {
        guard let pipe = pipes[model], let tokenizer = pipe.tokenizer else { return false }
        stopLiveDictation()   // never run two at once
        liveModel = model
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

        let transcriber = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipe.audioProcessor,
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
                let transcript = Self.cleanStreamText(confirmed + tail)
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
                Task { @MainActor in onUpdate(transcript, 0) }
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
            } catch {
                Log.live("stream ERROR — \(error)")
            }
        }
        return true
    }

    /// A copy of every sample captured so far this live session (16 kHz mono), from
    /// `model`'s audioProcessor. `model` is passed explicitly (not read from
    /// `liveModel`) so it stays valid across `stopLiveDictation()`, which clears
    /// `liveModel`. Grab this BEFORE stopping to keep the trailing audio.
    func liveSamplesSnapshot(model: String) -> [Float] {
        guard let pipe = pipes[model] else { return [] }
        return Array(pipe.audioProcessor.audioSamples)
    }

    /// Transcribe a raw sample array in full on `model`'s pipe. Used on release to
    /// produce the complete, accurate transcript — including the final sub-second
    /// the streaming loop never processed (it only runs on >1s of new buffer).
    /// `model` is explicit so this still works after `stopLiveDictation()`.
    func transcribeSamples(_ samples: [Float], model: String) async -> String? {
        guard let pipe = pipes[model], samples.count > 16_000 / 3 else { return nil }   // <~0.33s → skip
        let results: [TranscriptionResult]? =
            try? await pipe.transcribe(audioArray: samples, decodeOptions: decodeOptions())
        guard let results else { return nil }
        return Self.cleanStreamText(results.map { $0.text }.joined())
    }

    /// Decode options shared by every transcription path (file dictation, the live
    /// stream, and the final pass). `withoutTimestamps` matters for short clips:
    /// with timestamps on (WhisperKit's default) a <1s utterance often decodes to
    /// no content token at all — so quick dictations returned empty and nothing
    /// typed. `skipSpecialTokens` keeps `<|…|>` control tokens out of the text.
    private func decodeOptions() -> DecodingOptions {
        var options = DecodingOptions(language: "en")
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        return options
    }

    /// Belt-and-suspenders: strip any residual Whisper control tokens like
    /// `<|startoftranscript|>`, `<|en|>`, `<|0.00|>`, `<|endoftext|>` that can
    /// slip through even with skipSpecialTokens set, plus the placeholder.
    static func cleanStreamText(_ text: String) -> String {   // internal for tests
        var t = text.replacingOccurrences(of: "Waiting for speech...", with: "")
        if t.contains("<|") {
            t = t.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        }
        return t
    }

    /// Stop the live stream (ends its mic capture + realtime loop).
    func stopLiveDictation() {
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

    // MARK: - Selection / loading

    /// Point at `model`: mark ready if already loaded, else load it in the
    /// background if it's available (never auto-downloads). An already-loaded model
    /// keeps working until this one is ready.
    func select(_ model: String) {
        if pipes[model] != nil { statuses[model] = .ready; return }
        if loadingModels.contains(model) { return }        // already preparing
        if isDownloaded(model) {
            Task { await load(model) }
        } else {
            statuses[model] = .notDownloaded
        }
    }

    /// Download (if needed) then load `model`, reporting progress.
    func download(_ model: String) async {
        if pipes[model] != nil { statuses[model] = .ready; return }
        if !isDownloaded(model) {
            statuses[model] = .downloading(0)
            do {
                _ = try await WhisperKit.download(variant: model, downloadBase: basket) { [weak self] p in
                    Task { @MainActor in self?.statuses[model] = .downloading(p.fractionCompleted) }
                }
            } catch {
                statuses[model] = .failed("Download failed: \(error.localizedDescription)")
                return
            }
        }
        await load(model)
    }

    /// Delete the on-disk copy and fetch fresh (recovers a stale/partial download).
    func redownload(_ model: String) async {
        pipes.removeValue(forKey: model)
        removeDownloaded(model)
        await download(model)
    }

    /// Load a downloaded/bundled model in the background (Neural Engine, with a live
    /// stage + timeout). Swaps it in as a resident model only when it's fully ready,
    /// so anything already loaded keeps serving meanwhile.
    private func load(_ model: String) async {
        loadingModels.insert(model)
        statuses[model] = .preparing("Loading")
        Log.stt("load begin \(model) (bundled=\(bundledModelFolder(model) != nil))")
        let t0 = Date()

        let bundled = bundledModelFolder(model)
        let tokenizerRoot = bundled != nil ? bundledTokenizerRoot : basket
        // Default compute = Neural Engine (fastest transcription).
        let config: WhisperKitConfig
        if let bundled {
            config = WhisperKitConfig(model: model, modelFolder: bundled.path,
                                      tokenizerFolder: tokenizerRoot,
                                      prewarm: false, load: false, download: false)
        } else {
            config = WhisperKitConfig(model: model, downloadBase: basket,
                                      tokenizerFolder: tokenizerRoot,
                                      prewarm: false, load: false, download: true)
        }

        do {
            let p = try await withTimeout(seconds: 150) {
                let kit = try await WhisperKit(config)           // setup only — fast
                kit.modelStateCallback = { [weak self] _, new in
                    Task { @MainActor in
                        guard let self, self.loadingModels.contains(model) else { return }
                        self.statuses[model] = .preparing(new.description)  // live stage
                        Log.stt("stage \(model): \(new.description)")
                    }
                }
                try await kit.loadModels()                        // Neural Engine load — the work
                return kit
            }
            pipes[model] = p
            loadingModels.remove(model)
            statuses[model] = .ready
            Log.stt(String(format: "READY \(model) in %.1fs (resident: \(pipes.keys.sorted()))", Date().timeIntervalSince(t0)))
            NSLog("Slive: WhisperKit ready (\(model)).")
        } catch is TimeoutError {
            loadingModels.remove(model)
            statuses[model] = .failed("Timed out preparing this model. Try Re-download, or a smaller model.")
            Log.stt("TIMEOUT loading \(model)")
        } catch {
            loadingModels.remove(model)
            statuses[model] = .failed(error.localizedDescription)
            Log.stt("FAILED loading \(model) — \(error)")
            NSLog("Slive: WhisperKit load failed — \(error)")
        }
    }

    /// Transcribe `url` strictly using `model`'s pipe. If it isn't loaded yet, load
    /// it when it's available; returns nil otherwise (and kicks off a select) so the
    /// caller can tell the user what to do.
    func transcribe(_ url: URL, model: String) async -> String? {
        if pipes[model] == nil {
            guard isDownloaded(model) else { select(model); return nil }
            await load(model)
        }
        guard let pipe = pipes[model] else { return nil }
        do {
            let results = try await pipe.transcribe(
                audioPath: url.path,
                decodeOptions: decodeOptions()
            )
            return results
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("Slive: transcription failed — \(error)")
            return nil
        }
    }
}
