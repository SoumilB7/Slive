import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

@MainActor
enum ParakeetWindowTests {
    static let suite = TestSuite(name: "Parakeet live window") { t in
        print("[Parakeet live window]")
        func w(_ word: String, _ start: Double, _ end: Double) -> WordTiming {
            WordTiming(word: word, startTime: start, endTime: end)
        }
        let a = [w("we", 0, 0.3), w("ran", 0.4, 0.7), w("it", 0.8, 1.0), w("today", 3.0, 3.4)]
        let b = [w("We", 0, 0.3), w("ran", 0.4, 0.7), w("it,", 0.8, 1.0), w("today", 3.0, 3.4)]
        t.equal(ParakeetLiveSession.settledCount(previous: a, current: b, before: 2.5), 3,
              "agreeing words before the edge settle (case/punctuation ignored)")
        t.equal(ParakeetLiveSession.settledCount(previous: a, current: b, before: 0.9), 2,
              "a word still near the edge waits")
        let c = [w("we", 0, 0.3), w("run", 0.4, 0.7), w("it", 0.8, 1.0)]
        t.equal(ParakeetLiveSession.settledCount(previous: a, current: c, before: 2.5), 1,
              "settling stops at the first disagreement")
        t.equal(ParakeetLiveSession.settledCount(previous: [], current: b, before: 2.5), 0,
              "nothing settles on a first pass")
        t.equal(ParakeetLiveSession.join("we ran it", "And then we left"), "we ran it and then we left",
              "a mid-sentence window's capital is lowered")
        t.equal(ParakeetLiveSession.join("We ran it.", "Then we left"), "We ran it. Then we left",
              "a new sentence keeps its capital")
        t.equal(ParakeetLiveSession.join("and then", "I left"), "and then I left", "\"I\" stays capital")
        t.equal(ParakeetLiveSession.join("deploy the", "API now"), "deploy the API now", "acronyms stay")
        t.equal(ParakeetLiveSession.join("", "Hello"), "Hello", "no settled text yet")
    }
}
