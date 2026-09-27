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

    /// Transcribe one utterance. A fresh decoder state per call: every
    /// dictation is independent (no text carried over from the last one).
    func transcribe(_ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
