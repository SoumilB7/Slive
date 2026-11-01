import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

/// Text hygiene
@MainActor
enum TextHygieneTests {
    static let suite = TestSuite(name: "Text hygiene") { t in
        print("[Text hygiene]")
        t.equal(TranscriptionModel.cleanStreamText(
                "<|startoftranscript|><|en|><|transcribe|><|0.00|> hello world<|endoftext|>"),
              " hello world", "control tokens stripped")
        t.equal(TranscriptionModel.cleanStreamText("Waiting for speech..."), "", "placeholder stripped")
        t.equal(TranscriptionModel.cleanStreamText("just words"), "just words", "plain text untouched")

        t.equal(ContinuousDictation.normalize("  hello there"), "hello there", "leading spaces stripped")
        t.equal(ContinuousDictation.normalize("<|en|>hi"), "hi", "normalize strips tokens")
        t.equal(ContinuousDictation.normalize("Waiting for speech... hi"), "hi", "normalize strips placeholder")
        t.equal(ContinuousDictation.normalize("a  b"), "a  b", "inner spacing kept")
    }
}
