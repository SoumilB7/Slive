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
    /// character, rather than in per-pass bursts. A fresh one per session: a
    /// new hold during the previous session's final pass must not have its
    /// typist reset — or finished — by that stale stop.
    private var typist = LiveTypist()

    /// What a finished session produced. `typed` is false when no editable field
    /// was focused, so nothing could stream into it — the caller should surface
    /// `text` in the result box instead (as normal dictation does).
    struct Outcome {
        let text: String
        let typed: Bool
        /// ✕ (or quit) landed during the final pass: show nothing, record nothing.
        var cancelled = false
    }

    private var active = false
    /// The model this session is streaming with — captured at start so the final
    /// pass can target it after the live stream (and `liveModel`) is torn down.
    private var model = ""
    /// Whether this session is actually typing into a field (decided at start).
    private var typing = false
    /// Latest normalized transcript — the fallback text if the final pass fails.
    private var lastTranscript = ""
    /// The text stages, with the user's Vocabulary captured at start: every
    /// streamed pass and the final text are spelling-corrected against it, so
    /// the field never shows one spelling live and swaps to another on release.
    private var pipeline = DictationPipeline.live(vocabulary: "")

    /// Live mic energy (0…~1) forwarded for the waveform pill.
    var onEnergy: ((Float) -> Void)?
    /// The live stream failed after `start` returned (the mic wouldn't open).
    /// The session is already cancelled; the caller says so.
    var onFailure: (() -> Void)?
    /// Identifies the session, so a late failure or a ✕ can't touch a newer one.
    private var session = UUID()
    /// The session `cancel()` ended — its final pass, if running, must not type.
    private var cancelledSession: UUID?

    var isActive: Bool { active }

    /// Start streaming with `model` (the serving continuous model — the
    /// user's pick, or the previous one while the pick is still preparing)
    /// at the configured typing speed. Returns false if `model` isn't loaded
    /// (streaming can't wait on a first-time load — the caller surfaces that).
    func start(model: String) -> Bool {
        guard whisper.isReady(model) else {
            Log.live("start SKIPPED — model \(model) not ready")
            return false
        }
        self.model = model
        let session = UUID()
        self.session = session
        active = true
        lastTranscript = ""
        pipeline = .live(vocabulary: Settings.shared.hotwords)
        let canType = PasteEngine.canStreamType()
        typing = canType
        Log.live("start — model=\(model) cps=\(Int(Settings.shared.continuousTypeCPS)) canType=\(canType)")
        typist = LiveTypist()
        typist.start(allowed: canType, cps: Settings.shared.continuousTypeCPS,
                     target: canType ? PasteEngine.currentStreamTarget() : nil)
        let ok = whisper.startLiveDictation(model: model) { [weak self] transcript, energy in
            guard let self, self.active else { return }
            self.onEnergy?(energy)
            let text = self.pipeline.finish(transcript)
            self.lastTranscript = text
            // Just move the goal — the typist eases the field toward it smoothly.
            self.typist.setTarget(text)
        } onFailure: { [weak self] in
            guard let self, self.active, self.session == session else { return }
            self.cancel()
            self.onFailure?()
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
        // This session's own copies: a new start() during the final pass below
        // replaces all of these.
        let typist = self.typist, model = self.model, typing = self.typing
        let session = self.session
        let lastTranscript = self.lastTranscript, pipeline = self.pipeline
        let snapshot = whisper.liveSamplesSnapshot(model: model)   // grab BEFORE stopping
        let confirmedText = pipeline.clean(whisper.liveConfirmedText)
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
                                               tail: pipeline.clean(tailText))
                Log.live(String(format: "stitched release: tail %.1fs of %.1fs",
                                Double(tailSamples.count) / 16_000.0, duration))
            }
        }
        if final == nil {
            final = (await whisper.transcribeSamples(snapshot, model: model)).map(pipeline.clean)
        }
        // An empty final is a failed pass, not "the user said nothing": taken
        // at face value it backspaced the typed tail and returned no text.
        if final?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { final = nil }
        // Fall back to the last streamed transcript if the final pass fails
        // (already corrected; the stitched/full text is corrected here, after
        // the seam merge so a term split across the seam still matches).
        let finalText = final.map(pipeline.correct)
            ?? lastTranscript
        if cancelledSession == session {
            Log.live("cancelled during the final pass — nothing typed")
            return Outcome(text: "", typed: true, cancelled: true)
        }

        let result: String
        var typed = typing
        if typing {
            typist.setTarget(finalText)
            // Flush the remaining diff immediately so the field is correct on release.
            let done = await typist.finish()
            // Focus moved mid-session: typing stopped there, so hand back the
            // whole text for the copy box instead of the partial field.
            if done.focusLost { result = finalText; typed = false } else { result = done.text }
        } else {
            typist.cancel()
            result = finalText
        }
        Log.live(String(format: "DONE  final pass %.2fs  len=%d  «%@»",
                        Date().timeIntervalSince(t0), result.count, String(result.suffix(40))))
        return Outcome(text: result.trimmingCharacters(in: .whitespacesAndNewlines),
                       typed: typed)
    }

    /// Abort without a final pass or field edits (app quit / dismiss).
    func cancel() {
        cancelledSession = session
        active = false
        whisper.stopLiveDictation()
        typist.cancel()
    }

    // MARK: - Stitched release

    /// Holds longer than this get the stitched (tail-only) release decode.
    /// Was 60s (conservative first ship); the stitcher has since held up, and
    /// a full re-decode of even 20–60s on release is the single biggest
    /// release-latency cost — so any hold past ~12s now re-decodes only the
    /// unconfirmed tail (+0.3s seam pre-roll), making release time roughly
    /// constant regardless of hold length.
    private static let stitchedReleaseThreshold: TimeInterval = 12
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

    /// The live pipeline's cleanup (`StreamHygiene`, then `LeadingSpaceStrip`):
    /// drop Whisper's leading segment space (so the field doesn't start with
    /// a space) and strip anything unsafe. Control tokens / placeholder are
    /// already removed upstream; this is a final guard at the typing boundary.
    static func normalize(_ text: String) -> String {   // internal for tests
        DictationPipeline.live(vocabulary: "").clean(text)
    }
}
