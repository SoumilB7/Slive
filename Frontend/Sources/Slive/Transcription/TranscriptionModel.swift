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

/// Manages the on-device (WhisperKit) transcription model: checks whether it's
/// downloaded, downloads it in-app with progress, loads it, and transcribes.
///
/// Inference runs on WhisperKit's default compute (Neural Engine) for the fastest
/// transcription. The ANE needs a slow one-time "specialize" compile per model —
/// so the loading is built to never freeze or stick on it:
/// - Loading runs in the **background** and the currently-loaded model keeps
///   serving dictation until the new one is ready — the app never freezes on a
///   switch. The first load of a model is the only slow one; it's cached after.
/// - A live status (Downloading % / the WhisperKit load stage / Ready / Failed)
///   plus a hard timeout mean it never sits on a silent, stuck spinner.
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

    @Published private(set) var status: Status = .notDownloaded
    /// The currently-selected model these statuses refer to.
    @Published private(set) var model: String = ""

    private var pipe: WhisperKit?      // the working (loaded) model
    private var loadedModel: String?
    private var loadingModel: String?  // model being prepared in the background

    // Live streaming dictation (separate path from file transcription).
    private var liveTranscriber: AudioStreamTranscriber?

    /// Whether a model is loaded and ready to transcribe right now (streaming
    /// needs one already in memory — it can't wait on a first-time load).
    var isReady: Bool { pipe != nil }

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

    /// Release the loaded model from memory. Called on quit: the OS reclaims the
    /// process's memory on exit regardless, but dropping the WhisperKit instance
    /// deterministically frees its Core ML / Neural Engine resources first, and
    /// abandons any in-flight background load so nothing lingers.
    func shutdown() {
        stopLiveDictation()
        pipe = nil
        loadedModel = nil
        loadingModel = nil
    }

    // MARK: - Live streaming dictation

    /// Start real-time transcription from the mic. `onUpdate` fires on the main
    /// actor as speech is recognised, with the full running transcript so far
    /// (confirmed + still-forming tail, already cleaned) and recent mic energy
    /// (0…~1). The caller types it into the field with in-place correction.
    /// Returns false if no model is loaded yet. Runs until `stopLiveDictation()`.
    func startLiveDictation(
        onUpdate: @escaping @MainActor (_ transcript: String, _ energy: Float) -> Void
    ) -> Bool {
        guard let pipe, let tokenizer = pipe.tokenizer else { return false }
        stopLiveDictation()   // never run two at once
        // Fresh buffer per session — otherwise the shared audioProcessor would
        // still hold the previous utterance and re-transcribe it from the top.
        pipe.audioProcessor.purgeAudioSamples(keepingLast: 0)

        let transcriber = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipe.audioProcessor,
            decodingOptions: streamOptions(),
            // Confirm text after just one trailing segment (default is 2) so the
            // stable prefix grows sooner.
            requiredSegmentsForConfirmation: 1,
            useVAD: true,
            stateChangeCallback: { _, state in
                // Full transcript so far = confirmed prefix + still-forming tail.
                // (NOT state.currentText, which is the volatile decode and can be
                // an early hallucination or the "Waiting for speech..." placeholder.)
                let confirmed = state.confirmedSegments.map { $0.text }.joined()
                let tail = state.unconfirmedSegments.map { $0.text }.joined()
                let transcript = Self.cleanStreamText(confirmed + tail)
                let energy = state.bufferEnergy.last ?? 0
                Task { @MainActor in onUpdate(transcript, energy) }
            }
        )
        liveTranscriber = transcriber
        Task {
            do { try await transcriber.startStreamTranscription() }
            catch { NSLog("Slive: live dictation error — \(error)") }
        }
        return true
    }

    /// A copy of every sample captured so far this live session (16 kHz mono).
    /// Grab this BEFORE `stopLiveDictation()` to keep the trailing audio.
    func liveSamplesSnapshot() -> [Float] {
        guard let pipe else { return [] }
        return Array(pipe.audioProcessor.audioSamples)
    }

    /// Transcribe a raw sample array in full. Used on release to produce the
    /// complete, accurate transcript — including the final sub-second the
    /// streaming loop never processed (it only runs on >1s of new buffer).
    func transcribeSamples(_ samples: [Float]) async -> String? {
        guard let pipe, samples.count > 16_000 / 3 else { return nil }   // <~0.33s → skip
        let results: [TranscriptionResult]? =
            try? await pipe.transcribe(audioArray: samples, decodeOptions: streamOptions())
        guard let results else { return nil }
        return Self.cleanStreamText(results.map { $0.text }.joined())
    }

    /// Clean-text decode options shared by the live stream and the final pass.
    private func streamOptions() -> DecodingOptions {
        var options = DecodingOptions(language: "en")
        options.skipSpecialTokens = true   // no <|…|> control tokens
        options.withoutTimestamps = true
        return options
    }

    /// Belt-and-suspenders: strip any residual Whisper control tokens like
    /// `<|startoftranscript|>`, `<|en|>`, `<|0.00|>`, `<|endoftext|>` that can
    /// slip through even with skipSpecialTokens set, plus the placeholder.
    private static func cleanStreamText(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "Waiting for speech...", with: "")
        if t.contains("<|") {
            t = t.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        }
        return t
    }

    /// Stop the live stream (ends its mic capture + realtime loop).
    func stopLiveDictation() {
        guard let t = liveTranscriber else { return }
        liveTranscriber = nil
        Task { await t.stopStreamTranscription() }
    }

    // MARK: - Selection / loading

    /// Point at `model`: mark ready if already loaded, else load it in the
    /// background if it's available (never auto-downloads). The previously loaded
    /// model keeps working until this one is ready.
    func select(_ model: String) {
        self.model = model
        if loadedModel == model, pipe != nil { status = .ready; return }
        if loadingModel == model { return }               // already preparing
        if isDownloaded(model) {
            Task { await load(model) }
        } else {
            status = .notDownloaded
        }
    }

    /// Download (if needed) then load `model`, reporting progress.
    func download(_ model: String) async {
        self.model = model
        if loadedModel == model, pipe != nil { status = .ready; return }
        if !isDownloaded(model) {
            status = .downloading(0)
            do {
                _ = try await WhisperKit.download(variant: model, downloadBase: basket) { [weak self] p in
                    Task { @MainActor in self?.status = .downloading(p.fractionCompleted) }
                }
            } catch {
                status = .failed("Download failed: \(error.localizedDescription)")
                return
            }
        }
        await load(model)
    }

    /// Delete the on-disk copy and fetch fresh (recovers a stale/partial download).
    func redownload(_ model: String) async {
        if loadedModel == model { pipe = nil; loadedModel = nil }
        removeDownloaded(model)
        await download(model)
    }

    /// Load a downloaded/bundled model in the background (GPU, with live stage +
    /// timeout). Swaps it in as the working model only when it's fully ready, so
    /// the current one keeps serving dictation meanwhile.
    private func load(_ model: String) async {
        loadingModel = model
        status = .preparing("Loading")

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
                        guard let self, self.loadingModel == model else { return }
                        self.status = .preparing(new.description)  // live stage
                    }
                }
                try await kit.loadModels()                        // GPU load — the work
                return kit
            }
            pipe = p
            loadedModel = model
            loadingModel = nil
            if self.model == model { status = .ready }
            NSLog("Slive: WhisperKit ready (\(model)).")
        } catch is TimeoutError {
            loadingModel = nil
            status = .failed("Timed out preparing this model. Try Re-download, or a smaller model.")
        } catch {
            loadingModel = nil
            status = .failed(error.localizedDescription)
            NSLog("Slive: WhisperKit load failed — \(error)")
        }
    }

    /// Transcribe `url`. Uses whatever model is currently loaded (so dictation
    /// stays responsive even while a different model loads). If nothing is loaded
    /// yet, loads the selected one when it's available; returns nil otherwise so
    /// the caller can tell the user what to do.
    func transcribe(_ url: URL, model: String) async -> String? {
        if pipe == nil {
            guard isDownloaded(model) else { select(model); return nil }
            await load(model)
        }
        guard let pipe else { return nil }
        do {
            let results = try await pipe.transcribe(
                audioPath: url.path,
                decodeOptions: DecodingOptions(language: "en")
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
