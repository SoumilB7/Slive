import Foundation

/// One resident speech model, ready to decode — what `ResidencyManager`
/// holds, keyed by the persisted model id. Residency, timeouts, calibration
/// and failure reports are the `SpeechDecoder`'s; a recognizer only turns audio
/// into text.
@MainActor
protocol Recognizer: AnyObject {
    /// Decode one utterance (16 kHz mono), text ready to type.
    func transcribe(_ samples: [Float]) async throws -> String
    /// Whether `transcribe(fileAt:)` reads audio files itself. When false
    /// the decoder reads the samples and takes the sample path (with its
    /// too-short skip and calibration).
    var readsFiles: Bool { get }
    func transcribe(fileAt url: URL) async throws -> String
    /// The clip a warm-up decodes, given the bundled speech; nil = no warm-up.
    func warmUpClip(bundled: [Float]?) -> [Float]?
    func warmUp(_ audio: [Float]) async throws
    /// A live (continuous) session on this model; nil when it can't stream.
    func makeLiveSession(_ context: LiveContext) -> LiveSession?
    /// Audio its live stream captured and still holds (16 kHz mono).
    func streamedSamples() -> [Float]
}

extension Recognizer {
    var readsFiles: Bool { false }
    func transcribe(fileAt url: URL) async throws -> String {
        guard let samples = AudioClip.read16kMono(url) else { throw CocoaError(.fileReadCorruptFile) }
        return try await transcribe(samples)
    }
    func warmUpClip(bundled: [Float]?) -> [Float]? { bundled }
    func warmUp(_ audio: [Float]) async throws { _ = try await transcribe(audio) }
    func makeLiveSession(_ context: LiveContext) -> LiveSession? { nil }
    func streamedSamples() -> [Float] { [] }
}
