import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

/// WPM math
@MainActor
enum WpmTests {
    static let suite = TestSuite(name: "WPM math") { t in
        print("[WPM math]")
        let text30 = Array(repeating: "word", count: 30).joined(separator: " ")
        if let w = SpeakingStats.wpm(text: text30, seconds: 12) {
            t.check(abs(w - 150) < 0.001, "30 words / 12s = 150 WPM", "got \(w)")
        } else {
            t.check(false, "30 words / 12s = 150 WPM", "returned nil")
        }
        t.check(SpeakingStats.wpm(text: "", seconds: 5) == nil, "no words rejected")
        t.check(SpeakingStats.wpm(text: "   ", seconds: 5) == nil, "whitespace-only rejected")
        t.check(SpeakingStats.wpm(text: "hi", seconds: 0.3) == nil, "sub-0.5s rejected")
        let burst = Array(repeating: "w", count: 100).joined(separator: " ")
        t.check(SpeakingStats.wpm(text: burst, seconds: 1) == nil, "6000 WPM rejected as implausible")
        if let w = SpeakingStats.wpm(text: "a b\tc\nd", seconds: 60) {
            t.check(abs(w - 4) < 0.001, "words split on any whitespace", "got \(w)")
        } else {
            t.check(false, "words split on any whitespace", "returned nil")
        }
    }
}
