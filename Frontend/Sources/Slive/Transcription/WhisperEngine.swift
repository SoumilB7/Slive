import Foundation
import WhisperKit

/// On-device speech-to-text via **WhisperKit** — Whisper running on the Apple
/// Neural Engine / GPU (Core ML). Fast and low-RAM, entirely local; the Python
/// backend is no longer involved in transcription.
///
/// An actor so model loading and transcription are serialized safely. The model
/// downloads once on first use (cached by WhisperKit), so we preload at launch.
actor WhisperEngine {
    private var pipe: WhisperKit?
    private var loadedModel: String?

    enum EngineError: Error, CustomStringConvertible {
        case notReady
        var description: String { "Transcription model isn't ready yet." }
    }

    /// Load (or switch to) a model. Downloads it the first time — can take a
    /// while for large models — then keeps it warm. Safe to call repeatedly.
    func load(_ model: String) async {
        if loadedModel == model && pipe != nil { return }
        do {
            let config = WhisperKitConfig(model: model)
            let p = try await WhisperKit(config)
            pipe = p
            loadedModel = model
            NSLog("Slive: WhisperKit ready (\(model)).")
        } catch {
            NSLog("Slive: WhisperKit failed to load \(model) — \(error)")
            pipe = nil
            loadedModel = nil
        }
    }

    /// Transcribe a local audio file, loading `model` first if needed. Returns
    /// the trimmed text.
    func transcribe(_ url: URL, model: String) async throws -> String {
        if loadedModel != model || pipe == nil { await load(model) }
        guard let pipe else { throw EngineError.notReady }

        let results = try await pipe.transcribe(
            audioPath: url.path,
            decodeOptions: DecodingOptions(language: "en")
        )
        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
