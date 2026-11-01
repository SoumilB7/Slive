import Foundation

/// A loaded Parakeet model (`ParakeetEngine`). Files are read into samples
/// and decoded like any dictation; continuous mode runs its own window loop
/// (`ParakeetLiveSession`).
@MainActor
final class ParakeetRecognizer: Recognizer {
    let engine: ParakeetEngine

    init(_ engine: ParakeetEngine) { self.engine = engine }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await engine.transcribe(samples)
    }

    func makeLiveSession(_ context: LiveContext) -> LiveSession? {
        ParakeetLiveStream(engine: engine, context: context)
    }
}

/// Parakeet's load: compile + load onto the Neural Engine from Slive's
/// basket, then the same ready/serving/warm-up path as Whisper.
@MainActor
struct ParakeetLoader: ModelLoader {
    let storage: ParakeetStorage

    func plan(_ id: String) -> LoadPlan? {
        guard let model = ParakeetModel(rawValue: id) else { return nil }
        let basket = storage.basket.url
        return LoadPlan(
            firstStage: "Compiling",
            detail: "parakeet",
            load: { _ in ParakeetRecognizer(try await ParakeetEngine.load(model, basket: basket)) },
            interim: nil,
            copy: LoadFailureCopy(engine: "Parakeet",
                                  timedOutStatus: "Timed out. Re-download.",
                                  timedOutReport: "The Parakeet model didn't finish loading.",
                                  failedReport: "The Parakeet model failed to load."))
    }
}
