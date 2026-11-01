import CoreML
import Foundation
import WhisperKit

/// A loaded WhisperKit pipeline.
///
/// Inference runs on WhisperKit's default compute (Neural Engine) for the
/// fastest transcription; the ANE's slow one-time "specialize" compile per
/// model is `WhisperLoader`'s problem (CPU copy meanwhile).
@MainActor
final class WhisperRecognizer: Recognizer {
    let kit: WhisperKit
    /// The live stream filling this pipeline's audio processor right now.
    weak var stream: WhisperLiveSession?

    init(_ kit: WhisperKit) { self.kit = kit }

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
    nonisolated static func decodeOptions(chunking: Bool = false) -> DecodingOptions {
        var options = DecodingOptions(language: "en")
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.temperatureFallbackCount = 1
        if chunking {
            options.chunkingStrategy = .vad
        }
        return options
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let options = Self.decodeOptions(chunking: true)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return StreamHygiene.clean(results.map { $0.text }.joined())
    }

    var readsFiles: Bool { true }

    func transcribe(fileAt url: URL) async throws -> String {
        let options = Self.decodeOptions(chunking: true)
        let results = try await kit.transcribe(audioPath: url.path, decodeOptions: options)
        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func warmUpClip(bundled: [Float]?) -> [Float]? {
        bundled ?? [Float](repeating: 0, count: 8_000)
    }

    func warmUp(_ audio: [Float]) async throws {
        let options = Self.decodeOptions()
        _ = try await kit.transcribe(audioArray: audio, decodeOptions: options)
    }

    func makeLiveSession(_ context: LiveContext) -> LiveSession? {
        guard let tokenizer = kit.tokenizer else { return nil }
        return WhisperLiveSession(recognizer: self, tokenizer: tokenizer, context: context)
    }

    func streamedSamples() -> [Float] { Array(kit.audioProcessor.audioSamples) }
}

/// Loads WhisperKit models: bundled, installed fine-tunes, or the basket.
@MainActor
struct WhisperLoader: ModelLoader {
    let storage: WhisperStorage

    func plan(_ model: String) -> LoadPlan? {
        let bundled = storage.bundledFolder(model)
        let custom = storage.customModel(model)
        let tokenizerRoot = custom?.tokenizerFolder ?? (bundled != nil ? storage.bundledTokenizerRoot : storage.basket.url)
        // A downloaded model loads from its folder with downloads off. With
        // download: true WhisperKit asked Hugging Face for the file list on
        // EVERY load — offline, a downloaded model failed to load at all.
        let downloaded = custom == nil && bundled == nil ? storage.downloadedFolder(model) : nil
        guard let folder = custom?.modelFolder ?? bundled ?? downloaded else { return nil }
        // Encoder + decoder on the Neural Engine (fastest — `--bench-compute`:
        // GPU/CPU are ~3× slower per token). The mel spectrogram on the CPU:
        // WhisperKit's default puts it on the GPU, whose compiled MPSGraph
        // cache entry stops loading whenever a different Slive binary has
        // touched the shared cache ("Unable to load MPSGraphExecutable") —
        // every rebuild/reinstall then recompiled it for ~1–2 minutes before
        // ANY dictation could run. On CPU: load 100.6s → 10.8s on a fresh
        // binary, and the stage itself is faster (4ms vs 16ms per clip).
        func makeConfig(_ compute: ModelComputeOptions) -> WhisperKitConfig {
            WhisperKitConfig(model: model, modelFolder: folder.path,
                             tokenizerFolder: tokenizerRoot, computeOptions: compute,
                             prewarm: false, load: false, download: false)
        }
        let config = makeConfig(ModelComputeOptions(melCompute: .cpuOnly))
        return LoadPlan(
            firstStage: "Loading",
            detail: "bundled=\(bundled != nil)",
            load: { stage in
                let kit = try await WhisperKit(config)           // setup only — fast
                kit.modelStateCallback = { _, new in
                    Task { @MainActor in stage(new.description) }   // live stage
                }
                // Test hook: a Neural Engine load that never finishes (the
                // Nov 5 fresh-install hang) — the CPU copy must still serve.
                if ProcessInfo.processInfo.environment["SLIVE_TEST_ANE_HANG"] == "1" {
                    try await Task.sleep(nanoseconds: 3_600_000_000_000)
                }
                try await kit.loadModels()                        // Neural Engine load — the work
                return WhisperRecognizer(kit)
            },
            // A slow Neural Engine compile (memory pressure, a busy compiler —
            // Nov 5: a fresh install sat on "Loading…" ~20 min) shouldn't block
            // dictation: after a grace period, load a CPU copy (no compile, ready
            // in seconds) and serve from it; the Neural Engine copy replaces it.
            interim: LoadPlan.Interim(
                after: Self.cpuCopyDelay(model: custom?.baseModel ?? model,
                                         physicalMemory: ProcessInfo.processInfo.physicalMemory),
                load: {
                    let cpu = makeConfig(ModelComputeOptions(
                        melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly,
                        textDecoderCompute: .cpuOnly, prefillCompute: .cpuOnly))
                    guard let kit = try? await WhisperKit(cpu), (try? await kit.loadModels()) != nil else { return nil }
                    return WhisperRecognizer(kit)
                }),
            copy: LoadFailureCopy(engine: "WhisperKit",
                                  timedOutStatus: "Timed out. Re-download or pick smaller.",
                                  timedOutReport: "The speech model didn't finish loading in 10 minutes.",
                                  failedReport: "The speech model failed to load."))
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
}
