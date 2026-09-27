import FluidAudio
import Foundation

/// One loaded Parakeet model — a thin wrapper over FluidAudio's `AsrManager`.
///
/// Engine only: it loads a model and turns 16 kHz mono Float32 samples into
/// text. Where models are stored, download progress and UI status belong to
/// the provisioning layer; residency, warm-up and the dictation path to
/// TranscriptionModel.
final class ParakeetEngine: @unchecked Sendable {
    let model: ParakeetModel
    private let manager: AsrManager
    private let decoderLayers: Int

    private init(model: ParakeetModel, manager: AsrManager, decoderLayers: Int) {
        self.model = model
        self.manager = manager
        self.decoderLayers = decoderLayers
    }

    /// Download (if needed) and load `model` onto the Neural Engine.
    /// `directory` nil = FluidAudio's default model cache.
    static func load(_ model: ParakeetModel, directory: URL? = nil) async throws -> ParakeetEngine {
        let models = try await AsrModels.downloadAndLoad(to: directory, version: model.asrVersion)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return ParakeetEngine(model: model, manager: manager,
                              decoderLayers: await manager.decoderLayerCount)
    }

    // MARK: - Provisioning (where models live in Slive's basket)

    /// `<basket>/parakeet/<FluidAudio's folder name>` — the folder name comes
    /// from FluidAudio's own public cache path, so it can never drift from
    /// what its download/load/exists checks expect.
    static func directory(for model: ParakeetModel, basket: URL) -> URL {
        basket.appendingPathComponent("parakeet", isDirectory: true)
            .appendingPathComponent(AsrModels.defaultCacheDirectory(for: model.asrVersion).lastPathComponent,
                                    isDirectory: true)
    }

    static func isDownloaded(_ model: ParakeetModel, basket: URL) -> Bool {
        AsrModels.modelsExist(at: directory(for: model, basket: basket), version: model.asrVersion)
    }

    /// Put `model` in Slive's basket. If FluidAudio's shared cache already
    /// holds a complete copy (another FluidAudio app, or the Sep 2026 trial),
    /// clone it — `copyItem` on APFS is a clonefile: instant, no extra disk —
    /// instead of downloading ~0.5 GB again. The shared copy is left intact
    /// for whoever else uses it. Otherwise download with progress (0…1).
    static func download(_ model: ParakeetModel, basket: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let target = directory(for: model, basket: basket)
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let shared = AsrModels.defaultCacheDirectory(for: model.asrVersion)
        if !fm.fileExists(atPath: target.path),
           AsrModels.modelsExist(at: shared, version: model.asrVersion) {
            try fm.copyItem(at: shared, to: target)
            if isDownloaded(model, basket: basket) { progress(1); return }
            try? fm.removeItem(at: target)   // incomplete clone → fall through to a real download
        }
        _ = try await AsrModels.download(to: target, version: model.asrVersion) { p in
            progress(p.fractionCompleted)
        }
    }

    /// Load a provisioned model from Slive's basket onto the Neural Engine
    /// (the first load of a new build compiles it — tens of seconds).
    static func load(_ model: ParakeetModel, basket: URL) async throws -> ParakeetEngine {
        let models = try await AsrModels.load(from: directory(for: model, basket: basket),
                                              version: model.asrVersion)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return ParakeetEngine(model: model, manager: manager,
                              decoderLayers: await manager.decoderLayerCount)
    }

    static func remove(_ model: ParakeetModel, basket: URL) {
        try? FileManager.default.removeItem(at: directory(for: model, basket: basket))
    }

    /// Transcribe one utterance. A fresh decoder state per call: every
    /// dictation is independent (no text carried over from the last one).
    func transcribe(_ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
