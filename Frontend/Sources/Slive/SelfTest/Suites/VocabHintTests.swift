import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

/// Ground-truth vocabulary hint
@MainActor
enum VocabHintTests {
    static let suite = TestSuite(name: "Vocab hint") { t in
        print("[Vocab hint]")
        t.check(GroundTruthClient.vocabHint(hotwords: "", context: "") == nil
                && GroundTruthClient.vocabHint(hotwords: "  \n", context: " ") == nil,
              "no vocabulary configured → no hint sent")
        let wordsOnly = GroundTruthClient.vocabHint(hotwords: "Slive, Yara Jinkia", context: "")
        t.check(wordsOnly?.contains("Yara Jinkia") == true
                && wordsOnly?.contains("exact spellings") == true,
              "hotwords compose into a spelling hint")
        let both = GroundTruthClient.vocabHint(hotwords: "Slive", context: "software dictation")
        t.check(both?.contains("Slive") == true && both?.contains("software dictation") == true,
              "hotwords and context both ride along")
        t.check(GroundTruthClient.vocabHint(hotwords: "", context: "only context") != nil,
              "context alone still produces a hint")
    }
}
