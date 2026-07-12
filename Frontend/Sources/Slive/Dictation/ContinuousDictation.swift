import Foundation

/// Owns the live "continuous dictation" flow end-to-end, kept deliberately
/// separate from the main press-and-release dictation so the two never interfere
/// with each other's state.
///
/// While the key is held it streams transcription from the mic and types words
/// into the focused field with low latency, correcting the still-forming tail in
/// place (backspace + retype) as the recogniser revises it. On release it runs
/// one final full transcription of the whole utterance so the last sub-second —
/// which the streaming loop never processes (it only runs on >1s of new audio) —
/// is captured and the text ends up accurate.
///
/// Only the *tail* is ever rewritten: the confirmed prefix is stable, so
/// backspacing is bounded to the last few forming words.
@MainActor
final class ContinuousDictation {
    private let whisper = TranscriptionModel.shared
    /// Paces the actual keystrokes so text appears smoothly, character by
    /// character, rather than in per-pass bursts.
    private let typist = LiveTypist()

    /// What a finished session produced. `typed` is false when no editable field
    /// was focused, so nothing could stream into it — the caller should surface
    /// `text` in the result box instead (as normal dictation does).
    struct Outcome {
        let text: String
        let typed: Bool
    }

    private var active = false
    /// The model this session is streaming with — captured at start so the final
    /// pass can target it after the live stream (and `liveModel`) is torn down.
    private var model = ""
    /// Whether this session is actually typing into a field (decided at start).
    private var typing = false
    /// Latest normalized transcript — the fallback text if the final pass fails.
    private var lastTranscript = ""

    /// Live mic energy (0…~1) forwarded for the waveform pill.
    var onEnergy: ((Float) -> Void)?

    var isActive: Bool { active }

    /// Start streaming with the configured continuous model + typing speed. Returns
    /// false if that model isn't loaded (streaming can't wait on a first-time load —
    /// the caller should surface that).
    func start() -> Bool {
        let model = Settings.shared.continuousModel
        guard whisper.isReady(model) else {
            Log.live("start SKIPPED — model \(model) not ready")
            return false
        }
        self.model = model
        active = true
        lastTranscript = ""
        let canType = PasteEngine.canStreamType()
        typing = canType
        Log.live("start — model=\(model) cps=\(Int(Settings.shared.continuousTypeCPS)) canType=\(canType)")
        typist.start(allowed: canType, cps: Settings.shared.continuousTypeCPS)
        let ok = whisper.startLiveDictation(model: model) { [weak self] transcript, energy in
            guard let self, self.active else { return }
            self.onEnergy?(energy)
            let text = Self.normalize(transcript)
            self.lastTranscript = text
            // Just move the goal — the typist eases the field toward it smoothly.
            self.typist.setTarget(text)
        }
        if !ok { active = false; typist.cancel() }
        return ok
    }

    /// Stop streaming and run the final accurate pass (which captures the
    /// trailing audio the live loop missed). If this session was typing, the
    /// field is reconciled to the final transcript; if not (no editable field),
    /// the text is returned with `typed == false` so the caller can show it in
    /// the result box instead of it silently vanishing.
    func stop() async -> Outcome {
        guard active else { return Outcome(text: "", typed: typing) }
        active = false
        let snapshot = whisper.liveSamplesSnapshot(model: model)   // grab BEFORE stopping
        let confirmedText = Self.normalize(whisper.liveConfirmedText)
        let confirmedEnd = whisper.liveConfirmedEndSeconds
        whisper.stopLiveDictation()
        let duration = Double(snapshot.count) / 16_000.0
        Log.live(String(format: "RELEASE  audio=%.1fs  typing=%@  running final pass…",
                        duration, typing ? "yes" : "no"))
        let t0 = Date()

        // Long holds: a from-scratch decode of the WHOLE utterance on release
        // costs seconds-to-minutes. The streamed confirmed prefix is already
        // final text — re-decode only [confirmedEnd - preRoll … end] (the
        // trailing sub-second the stream never processed, plus the unconfirmed
        // span) and stitch it on, de-duplicating the deliberately-overlapped
        // seam. Short holds keep the exact full-decode path: it's already fast
        // there and immune to seam artifacts.
        var final: String?
        if duration > Self.stitchedReleaseThreshold,
           !confirmedText.isEmpty,
           confirmedEnd > 1, confirmedEnd < duration {
            let tailStart = max(0, Int((confirmedEnd - Self.seamPreRollSeconds) * 16_000.0))
            let tailSamples = Array(snapshot[tailStart...])
            if let tailText = await whisper.transcribeSamples(tailSamples, model: model) {
                final = Self.stitchTranscripts(confirmed: confirmedText,
                                               tail: Self.normalize(tailText))
                Log.live(String(format: "stitched release: tail %.1fs of %.1fs",
                                Double(tailSamples.count) / 16_000.0, duration))
            }
        }
        if final == nil {
            final = (await whisper.transcribeSamples(snapshot, model: model)).map(Self.normalize)
        }
        // Fall back to the last streamed transcript if the final pass fails.
        let finalText = final ?? lastTranscript

        let result: String
        if typing {
            typist.setTarget(finalText)
            // Flush the remaining diff immediately so the field is correct on release.
            result = await typist.finish()
        } else {
            typist.cancel()
            result = finalText
        }
        Log.live(String(format: "DONE  final pass %.2fs  len=%d  «%@»",
                        Date().timeIntervalSince(t0), result.count, String(result.suffix(40))))
        return Outcome(text: result.trimmingCharacters(in: .whitespacesAndNewlines),
                       typed: typing)
    }

    /// Abort without a final pass or field edits (app quit / dismiss).
    func cancel() {
        active = false
        whisper.stopLiveDictation()
        typist.cancel()
    }

    // MARK: - Stitched release

    /// Holds longer than this get the stitched (tail-only) release decode.
    private static let stitchedReleaseThreshold: TimeInterval = 60
    /// Re-decode this much audio BEFORE the confirmed boundary so the tail
    /// decode has context at the seam; the stitcher drops the duplicate words.
    private static let seamPreRollSeconds: Double = 0.3

    /// Merge the confirmed streamed text with a freshly-decoded tail that
    /// deliberately overlaps the seam: drop the tail's leading words that
    /// repeat the confirmed suffix. Words are compared case- and
    /// punctuation-insensitively ("Report." matches "report"); the confirmed
    /// side's rendering wins. No overlap found → plain join (never drops text).
    static func stitchTranscripts(confirmed: String, tail: String) -> String {
        let cw = confirmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let tw = tail.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !cw.isEmpty else { return tail }
        guard !tw.isEmpty else { return confirmed }
        func norm(_ w: String) -> String {
            w.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        var overlap = 0
        for k in stride(from: min(12, cw.count, tw.count), through: 1, by: -1) {
            if zip(cw.suffix(k), tw.prefix(k)).allSatisfy({ norm($0.0) == norm($0.1) }) {
                overlap = k
                break
            }
        }
        return (cw + tw.dropFirst(overlap)).joined(separator: " ")
    }

    // MARK: - Text hygiene

    /// Drop Whisper's leading segment space (so the field doesn't start with a
    /// space) and strip anything unsafe. Control tokens / placeholder are already
    /// removed upstream; this is a final guard at the typing boundary.
    static func normalize(_ text: String) -> String {   // internal for tests
        var t = text.replacingOccurrences(of: "Waiting for speech...", with: "")
        if t.contains("<|") {
            t = t.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        }
        while t.first == " " { t.removeFirst() }
        return t
    }
}
