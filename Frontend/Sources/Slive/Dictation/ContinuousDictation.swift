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

    private var active = false
    /// The model this session is streaming with — captured at start so the final
    /// pass can target it after the live stream (and `liveModel`) is torn down.
    private var model = ""

    /// Live mic energy (0…~1) forwarded for the waveform pill.
    var onEnergy: ((Float) -> Void)?

    var isActive: Bool { active }

    /// Start streaming with the configured continuous model + typing speed. Returns
    /// false if that model isn't loaded (streaming can't wait on a first-time load —
    /// the caller should surface that).
    func start() -> Bool {
        let model = Settings.shared.continuousModel
        guard whisper.isReady(model) else { return false }
        self.model = model
        active = true
        typist.start(allowed: PasteEngine.canStreamType(), cps: Settings.shared.continuousTypeCPS)
        let ok = whisper.startLiveDictation(model: model) { [weak self] transcript, energy in
            guard let self, self.active else { return }
            self.onEnergy?(energy)
            // Just move the goal — the typist eases the field toward it smoothly.
            self.typist.setTarget(Self.normalize(transcript))
        }
        if !ok { active = false; typist.cancel() }
        return ok
    }

    /// Stop streaming, reconcile the field to the final accurate transcript, and
    /// return the full text (already in the field). The final pass captures the
    /// trailing audio the live loop missed.
    func stop() async -> String {
        guard active else { return "" }
        active = false
        let snapshot = whisper.liveSamplesSnapshot(model: model)   // grab BEFORE stopping
        whisper.stopLiveDictation()
        NSLog(String(format: "Slive.live: RELEASE  audio=%.1fs  running final pass…",
                     Double(snapshot.count) / 16_000.0))
        let final = await whisper.transcribeSamples(snapshot, model: model)
        if let final { typist.setTarget(Self.normalize(final)) }
        // Flush the remaining diff immediately so the field is correct on release.
        let result = await typist.finish()
        NSLog(String(format: "Slive.live: DONE  final len=%d  (streaming had reached len=%d)",
                     final?.count ?? -1, result.count == 0 ? 0 : result.count))
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abort without a final pass or field edits (app quit / dismiss).
    func cancel() {
        active = false
        whisper.stopLiveDictation()
        typist.cancel()
    }

    // MARK: - Text hygiene

    /// Drop Whisper's leading segment space (so the field doesn't start with a
    /// space) and strip anything unsafe. Control tokens / placeholder are already
    /// removed upstream; this is a final guard at the typing boundary.
    private static func normalize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "Waiting for speech...", with: "")
        if t.contains("<|") {
            t = t.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        }
        while t.first == " " { t.removeFirst() }
        return t
    }
}
