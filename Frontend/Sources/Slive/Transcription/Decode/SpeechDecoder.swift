import Foundation

/// The one decode path, for every engine: the too-short skip, the timeout
/// scaled to the audio, the decode/warm-up bookkeeping (`beginDecode` /
/// `endDecode`), calibration from pure in-memory decodes, and the failure
/// report.
@MainActor
final class SpeechDecoder {
    /// Fewer samples than this (<~0.33s) never decode.
    nonisolated static let minSamples = 16_000 / 3

    /// A decode that hasn't returned by now never will: 60s plus twice the
    /// audio covers a long hold on a CPU copy of large-v3. Past it the
    /// dictation reports a failure instead of holding the queue forever.
    nonisolated static func timeoutSeconds(audioSeconds: Double) -> UInt64 {
        60 + UInt64(max(0, audioSeconds) * 2)
    }

    private let residency: ResidencyManager
    private let metrics: DecodeMetricsStore
    private let report: FaultSink
    /// The timeout for a clip of n seconds (the self-tests shorten it).
    private let timeout: (Double) -> UInt64

    init(residency: ResidencyManager, metrics: DecodeMetricsStore, report: FaultSink,
         timeout: @escaping (Double) -> UInt64 = SpeechDecoder.timeoutSeconds(audioSeconds:)) {
        self.residency = residency
        self.metrics = metrics
        self.report = report
        self.timeout = timeout
    }

    /// Transcribe a raw sample array in full on `model`. Used on release to
    /// produce the complete, accurate transcript — including the final
    /// sub-second the streaming loop never processed (it only runs on >1s of
    /// new buffer). Nil when `model` isn't resident or the clip is too short.
    func transcribe(_ samples: [Float], model: String) async -> String? {
        guard let recognizer = residency.recognizer(model), samples.count > Self.minSamples else { return nil }
        let audioSeconds = Double(samples.count) / 16_000
        let limit = timeout(audioSeconds)
        residency.markUsed()
        await residency.beginDecode(model)   // t0 after: the calibration measures this decode only
        defer { residency.endDecode(model) }
        let t0 = Date()
        let text: String
        do {
            text = try await withTimeout(seconds: limit, what: "decode") {
                try await recognizer.transcribe(samples)
            }
        } catch {
            reportFailure(model, error)
            return nil
        }
        // Pure decode on a resident model — the only honest calibration source.
        metrics.record(model: model, audioSeconds: audioSeconds, decodeSeconds: Date().timeIntervalSince(t0))
        return text
    }

    /// Transcribe the WAV at `url` on resident `model`. An engine that reads
    /// files itself decodes it in place (no calibration: file reads and
    /// long clips would skew it); any other reads the samples and takes the
    /// sample path.
    func transcribe(fileAt url: URL, model: String) async -> String? {
        guard let recognizer = residency.recognizer(model) else { return nil }
        guard recognizer.readsFiles else {
            guard let samples = AudioClip.read16kMono(url) else { return nil }
            return await transcribe(samples, model: model)
        }
        residency.markUsed()
        await residency.beginDecode(model)
        defer { residency.endDecode(model) }
        let seconds = AudioClip.seconds(url) ?? 300
        do {
            return try await withTimeout(seconds: timeout(seconds), what: "decode") {
                try await recognizer.transcribe(fileAt: url)
            }
        } catch {
            NSLog("Slive: transcription failed — \(error)")
            reportFailure(model, error)
            return nil
        }
    }

    /// A decode that threw or never returned is a real fault (silence and
    /// too-short clips never get here) — offer a report.
    private func reportFailure(_ model: String, _ error: Error) {
        if error is CancellationError { return }
        report("transcription",
               error is TimeoutError ? "A dictation's transcription never finished."
                                     : "Transcribing a dictation failed.",
               error: error, detail: "model \(model)")
    }
}
