import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

@MainActor
enum LiveTypingTests {
    static let suite = TestSuite(name: "Live typing") { t in
        print("[Live typing]")
        // Apply LiveTypist's plan the way reconcile does: keep old[0..<keep], type desired[from...].
        func field(_ old: String, _ desired: String, frozen: Int) -> String {
            let o = Array(old), d = Array(desired)
            let (keep, from) = LiveTypist.plan(old: o, desired: d, frozen: frozen)
            return String(o[0..<keep]) + (from < d.count ? String(d[from...]) : "")
        }
        let head = "we spent a lot of time on this and now the rest of it "
        t.equal(field(head + "is here", head + "is here and more", frozen: 40),
              head + "is here and more", "plain append past the freeze")
        t.equal(field(head + "is hear", head + "is here", frozen: 40),
              head + "is here", "a correction in the editable tail")
        // Revision BEHIND the freeze that shortens it ("a lot" → "allot"):
        // the frozen text stays, and the tail lines up — no dropped character.
        let revised = head.replacingOccurrences(of: "a lot", with: "allot")
        t.equal(field(head + "is", revised + "is here", frozen: 40),
              head + "is here", "a shorter revision behind the freeze doesn't eat a character")
        let longer = head.replacingOccurrences(of: "a lot", with: "a whole lot")
        t.equal(field(head + "is", longer + "is here", frozen: 40),
              head + "is here", "a longer revision behind the freeze doesn't double one")
        t.equal(field("", "hello", frozen: 0), "hello", "an empty field just types")

        let chunks = PasteEngine.unicodeChunks(String(repeating: "a", count: 45))
        t.equal(chunks.map { $0.utf16.count }, [20, 20, 5], "ASCII splits at 20 UTF-16 units")
        let emoji = String(repeating: "👍", count: 11)   // 2 units each
        t.check(PasteEngine.unicodeChunks(emoji).allSatisfy { $0.utf16.count <= 20 }
              && PasteEngine.unicodeChunks(emoji).joined() == emoji, "emoji never split across events")
        let accents = String(repeating: "e\u{301}", count: 15)  // base + combining mark
        t.check(PasteEngine.unicodeChunks(accents).allSatisfy { $0.utf16.count <= 20 && $0.count * 2 == $0.utf16.count },
              "a combining mark stays with its letter")
    }
}
