import Foundation

/// Post-decode spelling pass for the user's Vocabulary (Settings → Custom
/// words). The on-device engines never see the list — WhisperKit 0.9.4's
/// prompt tokens can come back empty, and Parakeet's vocabulary boosting
/// over-fired — but they do HEAR the terms; they just spell them a different
/// way each time ("Z docs", "ZDocs", "z docs" for z-docs; "on finance" for
/// onfinance; "CosMP agent" for cos-mp-agent). This rewrites those near-misses
/// to exactly what the user typed, and nothing else.
///
/// Deterministic and conservative — over-firing is the failure mode to fear:
///  - A run of 1–4 words matches a term when their letters and digits agree
///    once case, spaces, hyphens and dots are dropped ("Z docs" = "z-docs").
///  - Short terms (≤4 letters: cos, ios, curl) only ever match one whole
///    word exactly, so "cause", "eyes" and "curls" can't turn into them.
///  - Only long terms (≥8 letters) tolerate a one-letter slip ("POSMP agent"),
///    only when heard as several words, and only a substitution inside a word
///    of 4+ letters — "in finance" or "compliances" never become a term, and
///    neither does one real word a letter off a term ("internal" for the
///    term "interval").
///  - A trailing "s" counts as a plural only for identifier-shaped terms
///    ("CosMP agents" → "cos-mp-agents"); after a plain term it's usually a
///    different word ("on finances" is not onfinance).
///  - A term typed all-lowercase as plain words ("claude", "argo cd") says
///    nothing about casing, so a case-only difference is left alone: the
///    model's "Claude", "iOS" and "Argo CD" stay. Identifier-shaped terms
///    (hyphens, dots, digits — "z-docs") or ones with capitals ("OnFinance")
///    are exact spellings, casing included.
///  - A term whose plain letters are an ordinary English word ("IT", "US",
///    "Go", ".NET" → "net", "C#" → "c") would force its casing on every "it",
///    "us", "go", "net" and "c" the model writes. Those only apply when the
///    heard word already has the term's casing, or, for terms with symbols
///    (".NET", "C#"), when the heard text already has the symbol.
///  - Punctuation around a match and every other byte of the text is kept.
///    A term's own leading/trailing symbols ("C++", ".NET", "$HOME") already
///    in the text belong to the match — they used to be typed twice ("C++++").
///
/// Pure and nonisolated: runs on whatever thread produced the text, and the
/// self-test drives it directly.
public enum VocabularyCorrector {
    /// One vocabulary entry: the user's exact spelling and its match key.
    public struct Term: Equatable, Sendable {
        public let form: String
        public let key: String
        /// The form dictates casing too (has capitals or is identifier-shaped).
        public let enforcesCase: Bool
        /// Hyphens, dots or digits — a name ("cos-mp-agent"), not a word.
        public var isIdentifier: Bool { form.contains { $0 == "-" || $0 == "." || $0.isNumber } }
        /// Its letters alone are a common word or a single letter ("IT", ".NET", "C#").
        public var isCommonWord: Bool { VocabularyCorrector.commonWords.contains(key) || (key.count == 1 && key.first!.isLetter) }
    }

    /// Short words people also add as terms. A term in this set needs
    /// confirmation before it rewrites anything. Lowercase, letters only.
    private nonisolated static let commonWords: Set<String> = [
        "it", "us", "am", "go", "net", "is", "on", "in", "at", "to", "as", "an", "or", "up", "so", "no",
        "do", "be", "me", "we", "he", "she", "ai", "ok", "id", "pm", "by", "if", "my", "of",
    ]

    /// Longest run of words a single term can be heard as.
    public nonisolated static let maxSpanWords = 4
    /// Terms this short only match a single whole word, exactly.
    public nonisolated static let shortTermLength = 4
    /// Terms at least this long tolerate one substituted letter.
    public nonisolated static let fuzzyMinLength = 8

    /// Correct `text` against the Custom words string as stored in Settings.
    /// Empty vocabulary → `text` unchanged.
    public nonisolated static func correct(_ text: String, hotwords: String) -> String {
        correct(text, terms: terms(from: hotwords))
    }

    /// Parse the Custom words field: comma- and/or newline-separated, trimmed,
    /// de-duplicated by match key (first spelling wins).
    public nonisolated static func terms(from hotwords: String) -> [Term] {
        var seen = Set<String>()
        var out: [Term] = []
        for raw in hotwords.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let form = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let key = matchKey(form)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let plainLowercase = form.allSatisfy { ($0.isLetter && $0.isLowercase) || $0 == " " }
            out.append(Term(form: form, key: key, enforcesCase: !plainLowercase))
        }
        return out
    }

    /// Lowercased letters and digits only: "Z-Docs" → "zdocs".
    public nonisolated static func matchKey<S: StringProtocol>(_ s: S) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Matching

    /// A whitespace-delimited word: `core` is it minus any leading/trailing
    /// punctuation ("(Z" → "Z", "docs." → "docs").
    private struct Word {
        let core: Range<String.Index>
        let key: String
        /// Only letters, digits, hyphens and dots inside — "I/O's" can't match.
        let eligible: Bool
        let leadsClean: Bool    // nothing stripped before the core
        let trailsClean: Bool   // nothing stripped after the core
    }

    public nonisolated static func correct(_ text: String, terms: [Term]) -> String {
        guard !terms.isEmpty else { return text }
        let words = words(in: text)
        var out = ""
        var cursor = text.startIndex
        var i = 0
        while i < words.count {
            var consumed = 1
            for n in stride(from: min(maxSpanWords, words.count - i), through: 1, by: -1) {
                let span = words[i..<(i + n)]
                guard spanIsContiguous(span),
                      let (replacement, term) = match(span, terms: terms) else { continue }
                let core = span.first!.core.lowerBound..<span.last!.core.upperBound
                let range = withEdgeSymbols(of: replacement, around: core, in: text, after: cursor)
                if term.isCommonWord, !confirmsCommonWord(term, heard: text[range], core: text[core]) { continue }
                let original = text[range]
                // A plain lowercase term never lowercases what the model
                // capitalised ("Claude", "iOS"). A rewrite at a sentence start
                // still uses the user's form as typed — no auto-capitalising.
                let keep = !term.enforcesCase && original.lowercased() == replacement.lowercased()
                out += text[cursor..<range.lowerBound]
                out += keep ? String(original) : replacement
                cursor = range.upperBound
                consumed = n
                break
            }
            i += consumed
        }
        out += text[cursor...]
        return out
    }

    /// A common-word term applies only on a sign the user meant the term. With
    /// symbols (".NET", "C#") that is the symbol already in the heard text:
    /// "C" alone has the casing but is still the letter. Without, it is the
    /// term's own casing. A trailing period or comma is the sentence's, not a
    /// symbol of the term ("a.m." heard as "am.").
    private nonisolated static func confirmsCommonWord(_ term: Term, heard: Substring, core: Substring) -> Bool {
        let isCore: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        let form = term.form
        guard let first = form.firstIndex(where: isCore), let last = form.lastIndex(where: isCore) else { return false }
        let lead = String(form.prefix { !isCore($0) })
        var trail = String(form.reversed().prefix { !isCore($0) }.reversed())
        if trail.allSatisfy({ ".,;:!?".contains($0) }) { trail = "" }
        if lead.isEmpty, trail.isEmpty { return core == form[first...last] }
        return heard.hasPrefix(lead) && heard.hasSuffix(trail)
    }

    /// `core` widened over the form's own leading/trailing symbols when the
    /// text already has them there (never back past `cursor`).
    private nonisolated static func withEdgeSymbols(of form: String, around core: Range<String.Index>,
                                                    in text: String, after cursor: String.Index) -> Range<String.Index> {
        let isCore: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        let lead = form.prefix { !isCore($0) }
        let trail = String(form.reversed().prefix { !isCore($0) }.reversed())
        var lower = core.lowerBound, upper = core.upperBound
        if !lead.isEmpty, text[cursor..<lower].hasSuffix(lead) { lower = text.index(lower, offsetBy: -lead.count) }
        if !trail.isEmpty, text[upper...].hasPrefix(trail) { upper = text.index(upper, offsetBy: trail.count) }
        return lower..<upper
    }

    /// The spelling `span` should take, and the term it matched — if any.
    private nonisolated static func match(_ span: ArraySlice<Word>,
                                          terms: [Term]) -> (String, Term)? {
        let key = span.map(\.key).joined()
        for term in terms where span.count == 1 || term.key.count > shortTermLength {
            if key == term.key { return (term.form, term) }
            // Plural of a long identifier: "CosMP agents" → "cos-mp-agents".
            // Not plain terms: "focus on finances" became "focus onfinances".
            if term.isIdentifier, term.key.count >= fuzzyMinLength, !term.key.hasSuffix("s"),
               key == term.key + "s" {
                return (term.form + "s", term)
            }
        }
        // The slip is for a term heard as SEVERAL words ("POSMP agent"); one
        // word a letter off a term is a real word ("internal" ≠ "interval").
        guard span.count > 1 else { return nil }
        for term in terms where term.key.count >= fuzzyMinLength && term.key.count == key.count {
            guard let slip = singleSubstitution(key, term.key) else { continue }
            // The slip must sit inside a real word, not flip a little one
            // ("in finance", "of finance" are different words, not mishearings).
            var offset = 0
            for word in span {
                if slip < offset + word.key.count {
                    if word.key.count >= shortTermLength { return (term.form, term) }
                    break
                }
                offset += word.key.count
            }
        }
        return nil
    }

    /// The index where two equal-length strings differ, if they differ in
    /// exactly one place.
    private nonisolated static func singleSubstitution(_ a: String, _ b: String) -> Int? {
        var index: Int?
        for (i, (x, y)) in zip(a, b).enumerated() where x != y {
            if index != nil { return nil }
            index = i
        }
        return index
    }

    /// A run of words can only be one term when every word is eligible and no
    /// punctuation separates them ("Z, docs" is two things).
    private nonisolated static func spanIsContiguous(_ span: ArraySlice<Word>) -> Bool {
        for (offset, word) in span.enumerated() {
            guard word.eligible else { return false }
            if offset > 0, !word.leadsClean { return false }
            if offset < span.count - 1, !word.trailsClean { return false }
        }
        return true
    }

    private nonisolated static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard !text[i].isWhitespace else { i = text.index(after: i); continue }
            var end = i
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            let token = text[i..<end]
            let isCore: (Character) -> Bool = { $0.isLetter || $0.isNumber }
            if let first = token.firstIndex(where: isCore),
               let last = token.lastIndex(where: isCore) {
                let core = first..<token.index(after: last)
                let eligible = text[core].allSatisfy { isCore($0) || $0 == "-" || $0 == "." }
                words.append(Word(core: core, key: matchKey(text[core]), eligible: eligible,
                                  leadsClean: first == i, trailsClean: core.upperBound == end))
            } else {
                // Bare punctuation ("—", "&") still breaks a span: "Z — docs".
                words.append(Word(core: i..<i, key: "", eligible: false,
                                  leadsClean: false, trailsClean: false))
            }
            i = end
        }
        return words
    }
}
