import Foundation
import SliveCore
import SliveTestKit

/// Transcript word-diff (Training table highlighting). The SwiftUI rendering
/// is checked app-side (TranscriptDiffStylingTests).
@MainActor
enum TranscriptDiffTests {
    static let suite = TestSuite(name: "TranscriptDiff — word-level LCS") { t in
        print("[TranscriptDiff — word-level LCS]")

        let equal = TranscriptDiff.matchMask(
            output: ["the", "same", "words"], truth: ["the", "same", "words"])
        t.check(equal == [true, true, true], "equal strings match fully")

        let insert = TranscriptDiff.matchMask(
            output: ["the", "model", "loads"],
            truth: ["the", "whisper", "model", "loads"])
        t.check(insert == [true, false, true, true], "insertion marks only the new word")

        let replace = TranscriptDiff.matchMask(
            output: ["whisper", "kit", "engine"],
            truth: ["WhisperKit", "engine"])
        t.check(replace == [false, true], "replacement (incl. case change) marks the corrected word")

        // Deletion (output had an extra word the truth dropped): every truth
        // word is on the LCS, so there's no word to recolor — instead the
        // word at the deletion site gets an underline, and the text stays
        // verbatim (one small mark, not a whole orange paragraph).
        let deletion = TranscriptDiff.diff(
            output: ["the", "the", "cat"], truth: ["the", "cat"])
        t.check(deletion.mask == [true, true], "deletion case matches every truth word")
        t.check(!deletion.deletionSites.isEmpty, "deletion case reports its site")
        let screenshotOutput = TranscriptDiff.words(
            "How is the legacy roles creeping in? Can you explain to me the flow? "
            + "Why are even the legacy roles making this issue? And also, where in code "
            + "are they actually being used? And since the DB doesn't have any mapping "
            + "for legacy roles, how did you even get to know that these were the roles assigned?")
        let screenshotTruth = TranscriptDiff.words(
            "How is the legacy roles creeping in? Can you explain me the flow? "
            + "Why are even the legacy roles making this issue? And also, where in code "
            + "are they actually being used? And since the DB doesn't have any mapping "
            + "for legacy roles, how did you even get to know that these were the roles assigned?")
        let screenshotDiff = TranscriptDiff.diff(
            output: screenshotOutput, truth: screenshotTruth)
        t.check(screenshotDiff.mask.allSatisfy { $0 }
                && screenshotDiff.deletionSites.count == 1,
              "full screenshot deletion keeps every remaining word unchanged")

        let emptyOut = TranscriptDiff.matchMask(output: [], truth: ["a", "b"])
        t.check(emptyOut == [false, false], "empty output marks all truth words changed")

        // Divergence — the "way off" flag's measure (flag fires above 0.5).
        // (Plain `check` here: a local mask named `equal` shadows the helper.)
        t.check(TranscriptDiff.divergence(output: "a b c d", truth: "a b c d") == 0,
              "identical strings diverge 0")
        t.check(TranscriptDiff.divergence(output: "a b c d", truth: "w x y z") == 1,
              "disjoint strings diverge 1")
        t.check(TranscriptDiff.divergence(output: "a b c d", truth: "a b y z") == 0.5,
              "half-changed diverges exactly 0.5 — at the flag boundary, not past it")
        t.check(TranscriptDiff.divergence(output: "a b c d", truth: "a x y z") > 0.5,
              "three-quarters-changed crosses the way-off boundary")
        t.check(TranscriptDiff.divergence(output: "", truth: "anything at all") == 1,
              "empty output vs text diverges 1")

        // A realistic long dictation (300 words, one corrected) must produce a
        // real word-diff — the old 200-word cap painted such rows all-orange.
        var longOut = (0..<300).map { "word\($0)" }
        var longTru = longOut
        longTru[150] = "corrected"
        let longMask = TranscriptDiff.matchMask(output: longOut, truth: longTru)
        t.check(longMask.filter { !$0 }.count == 1 && longMask[150] == false,
              "300-word diff marks exactly the one corrected word")
        longOut = []; longTru = []
    }
}
