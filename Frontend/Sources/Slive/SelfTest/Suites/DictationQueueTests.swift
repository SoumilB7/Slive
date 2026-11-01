import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

/// Vocabulary corrector (post-decode spelling)
@MainActor
enum DictationQueueTests {
    static let suite = TestSuite(name: "Dictation queue") { t in
        print("[Dictation queue]")
        let queue = DictationQueue()
        t.check(queue.isEmpty, "a new queue is empty")
        let a = queue.enqueue(), b = queue.enqueue(), c = queue.enqueue()
        t.equal(queue.count, 3, "three waiting dictations are queued")
        t.check(queue.isTurn(a) && !queue.isTurn(b) && !queue.isTurn(c), "the oldest dictation types first")
        t.check(queue.isLast(c) && !queue.isLast(a), "the newest dictation owns the overlay")
        queue.finish(b)
        t.check(queue.isTurn(a), "a later one finishing early (empty) doesn't jump the line")
        queue.finish(a)
        t.check(queue.isTurn(c), "finishing the oldest hands the turn to the next")
        queue.finish(c)
        t.check(queue.isEmpty, "the queue drains")
        queue.finish(UUID())
        t.check(queue.isEmpty, "finishing an unknown dictation is harmless")
    }
}
