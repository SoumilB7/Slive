import SliveTestKit
import SwiftUI

/// The Training table's rendering of the word diff (the diff itself:
/// TranscriptDiffTests in SliveCoreSuites).
@MainActor
enum TranscriptDiffStylingTests {
    static let suite = TestSuite(name: "TranscriptDiff styling") { t in
        print("[TranscriptDiff styling]")

        // A deletion-only correction has no truth word to recolor — the word
        // at the deletion site gets an underline, and the text stays verbatim
        // (one small mark, not a whole orange paragraph).
        let deletionStyled = TranscriptDiff.attributed(
            output: "the the cat", truth: "the cat", base: .white, changed: .orange)
        t.check(deletionStyled != nil, "deletion-only correction renders a real diff")
        if let deletionStyled {
            t.check(String(deletionStyled.characters) == "the cat",
                  "deletion rendering keeps the truth text verbatim")
            t.check(deletionStyled.runs.contains { $0.underlineStyle != nil },
                  "deletion site is underlined")
        }
        // The screenshot case: "explain to me" → "explain me" must underline
        // one word, not orange the sentence.
        let dropTo = TranscriptDiff.attributed(
            output: "can you explain to me the flow",
            truth: "can you explain me the flow", base: .white, changed: .orange)
        t.check(dropTo != nil
                && dropTo.map { String($0.characters) } == "can you explain me the flow"
                && dropTo!.runs.contains { $0.underlineStyle != nil },
              "a single dropped word underlines its neighbor only")

        let short = TranscriptDiff.attributed(
            output: "hello there world", truth: "hello brave world",
            base: .white, changed: .orange)
        t.check(short != nil, "short strings produce an attributed diff")
        if let short {
            t.check(String(short.characters) == "hello brave world",
                  "attributed diff preserves the truth text verbatim")
        }

        let longWords = Array(repeating: "w", count: TranscriptDiff.maxWords + 1)
            .joined(separator: " ")
        let over = TranscriptDiff.attributed(
            output: "short", truth: longWords, base: .white, changed: .orange)
        t.check(over == nil, "over-length input falls back to whole-string styling (nil)")
    }
}
