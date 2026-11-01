import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

/// Stitched release (seam merger)
@MainActor
enum StitchTests {
    static let suite = TestSuite(name: "Stitch seam") { t in
        print("[Stitch seam]")
        // Exact duplicated words at the seam are dropped.
        t.equal(ContinuousDictation.stitchTranscripts(
                confirmed: "the quarterly report", tail: "quarterly report is due Friday"),
              "the quarterly report is due Friday", "seam dedup")
        // Case + punctuation differences still match; confirmed rendering wins.
        t.equal(ContinuousDictation.stitchTranscripts(
                confirmed: "we shipped it. The Report,", tail: "the report is late"),
              "we shipped it. The Report, is late", "case/punct-insensitive seam")
        // No overlap → plain join, nothing dropped.
        t.equal(ContinuousDictation.stitchTranscripts(
                confirmed: "hello world", tail: "goodbye moon"),
              "hello world goodbye moon", "no-overlap join")
        // Empty sides pass through.
        t.equal(ContinuousDictation.stitchTranscripts(confirmed: "", tail: "only tail"),
              "only tail", "empty confirmed")
        t.equal(ContinuousDictation.stitchTranscripts(confirmed: "only confirmed", tail: ""),
              "only confirmed", "empty tail")
        // Longest overlap wins over a shorter accidental one.
        t.equal(ContinuousDictation.stitchTranscripts(
                confirmed: "so so it goes", tail: "so it goes on and on"),
              "so so it goes on and on", "longest overlap preferred")
        // A repeated-phrase tail isn't over-trimmed (only the seam overlap goes).
        t.equal(ContinuousDictation.stitchTranscripts(
                confirmed: "again and again", tail: "and again and again we tried"),
              "again and again and again we tried", "repeat phrase not over-trimmed")
    }
}
