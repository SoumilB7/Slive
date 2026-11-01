import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

/// Dictation routing (who queues, early hand-off)
@MainActor
enum DictationRoutingTests {
    static let suite = TestSuite(name: "Dictation routing") { t in
        print("[Dictation routing]")
        // Oct 29: a dictation released with the model READY was cancelled by
        // the next hold — every dictation queues now.
        t.check(DictationQueue.queues(.dictate, modelReady: true, queueEmpty: true),
              "a dictation queues even with the model ready")
        t.check(DictationQueue.queues(.dictate, modelReady: false, queueEmpty: false),
              "a dictation queues behind a loading model")
        t.check(!DictationQueue.queues(.assist, modelReady: true, queueEmpty: true),
              "an assistant request with nothing in line stays supersedable")
        t.check(DictationQueue.queues(.assist, modelReady: false, queueEmpty: true),
              "an assistant request waits for a loading model")
        t.check(DictationQueue.queues(.assist, modelReady: true, queueEmpty: false),
              "an assistant request waits behind queued dictations")

        // A queued assistant hands its turn on as soon as its question is in
        // hand, then its task's defer finishes it again — must be a no-op.
        let queue = DictationQueue()
        let dictation = queue.enqueue(), assist = queue.enqueue(), later = queue.enqueue()
        queue.finish(dictation)
        t.check(queue.isTurn(assist), "the assistant request gets its turn")
        queue.finish(assist)   // early hand-off, before the LLM stream
        t.check(queue.isTurn(later) && queue.isLast(later), "the later dictation types without waiting on the answer")
        queue.finish(assist)   // the task's defer, after the stream
        t.check(queue.isTurn(later) && queue.count == 1, "finishing the assistant twice is harmless")
        queue.finish(later)
        t.check(queue.isEmpty, "the queue drains after an early hand-off")
    }
}
