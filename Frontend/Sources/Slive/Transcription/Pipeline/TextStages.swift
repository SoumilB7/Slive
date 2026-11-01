import Foundation

/// Belt-and-suspenders: strip any residual Whisper control tokens like
/// `<|startoftranscript|>`, `<|en|>`, `<|0.00|>`, `<|endoftext|>` that can
/// slip through even with skipSpecialTokens set, plus the placeholder.
struct StreamHygiene: TextStage {
    func apply(_ text: String) -> String { Self.clean(text) }

    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "Waiting for speech...", with: "")
        if t.contains("<|") {
            t = t.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        }
        return t
    }
}

/// Drop Whisper's leading segment space so a live field doesn't start with
/// one — a final guard at the typing boundary (inner spacing is kept).
struct LeadingSpaceStrip: TextStage {
    func apply(_ text: String) -> String {
        var t = text
        while t.first == " " { t.removeFirst() }
        return t
    }
}

/// Spell the user's Vocabulary terms the way they typed them (every engine;
/// a no-op when the list is empty). See `VocabularyCorrector`.
struct VocabularyCorrection: TextStage {
    /// Parsed once per pipeline, not once per live pass.
    let terms: [VocabularyCorrector.Term]

    /// `hotwords`: the Custom words string as stored in Settings.
    init(hotwords: String) { terms = VocabularyCorrector.terms(from: hotwords) }

    func apply(_ text: String) -> String { VocabularyCorrector.correct(text, terms: terms) }
}
