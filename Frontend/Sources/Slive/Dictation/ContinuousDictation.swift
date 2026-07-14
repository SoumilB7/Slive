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

    /// Exactly what we've typed into the field so far — diffed against each new
    /// transcript to compute the minimal backspace + type edit.
    private var typed = ""
    private var active = false

    /// Live mic energy (0…~1) forwarded for the waveform pill.
    var onEnergy: ((Float) -> Void)?

    var isActive: Bool { active }

    /// Start streaming. Returns false if no model is loaded (streaming can't wait
    /// on a first-time load — the caller should surface that).
    func start() -> Bool {
        guard whisper.isReady else { return false }
        typed = ""
        active = true
        let ok = whisper.startLiveDictation { [weak self] transcript, energy in
            guard let self, self.active else { return }
            self.onEnergy?(energy)
            self.apply(target: Self.normalize(transcript))
        }
        if !ok { active = false }
        return ok
    }

    /// Stop streaming, reconcile the field to the final accurate transcript, and
    /// return the full text (already in the field). The final pass captures the
    /// trailing audio the live loop missed.
    func stop() async -> String {
        guard active else { return "" }
        active = false
        let snapshot = whisper.liveSamplesSnapshot()   // grab BEFORE stopping
        whisper.stopLiveDictation()
        if let final = await whisper.transcribeSamples(snapshot) {
            apply(target: Self.normalize(final))
        }
        let result = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        typed = ""
        return result
    }

    /// Abort without a final pass or field edits (app quit / dismiss).
    func cancel() {
        active = false
        whisper.stopLiveDictation()
        typed = ""
    }

    // MARK: - Incremental typing

    /// Make the field's text match `target` with the fewest keystrokes: keep the
    /// common prefix, backspace the diverging suffix we typed, then type the new
    /// suffix.
    private func apply(target: String) {
        guard target != typed else { return }
        let old = Array(typed), new = Array(target)
        var common = 0
        let maxCommon = min(old.count, new.count)
        while common < maxCommon && old[common] == new[common] { common += 1 }

        let deletes = old.count - common
        let insert = String(new[common...])
        guard deletes > 0 || !insert.isEmpty else { return }
        PasteEngine.streamEdit(deleteCount: deletes, insert: insert)
        typed = target
    }

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
