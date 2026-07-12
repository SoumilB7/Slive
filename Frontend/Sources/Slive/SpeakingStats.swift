import Foundation

/// Tracks how fast you speak — words per minute — measured *after* each
/// dictation's text has already been written into the field. Nothing in the
/// transcribe/type hot path waits on this: `record` is called once the text is
/// down, so measuring never adds latency to what you see appear.
///
/// The running average / best survive relaunches (UserDefaults-backed).
@MainActor
final class SpeakingStats: ObservableObject {
    static let shared = SpeakingStats()

    /// Most recent dictation's pace (WPM). 0 = nothing measured yet.
    @Published private(set) var lastWPM: Double
    /// Running mean across every measured dictation.
    @Published private(set) var averageWPM: Double
    /// Fastest single dictation seen.
    @Published private(set) var bestWPM: Double
    /// How many dictations have contributed to the running stats.
    @Published private(set) var sampleCount: Int

    private enum Keys {
        static let last = "wpm.last"
        static let average = "wpm.average"
        static let best = "wpm.best"
        static let count = "wpm.count"
    }

    private init() {
        let d = UserDefaults.standard
        lastWPM = d.double(forKey: Keys.last)
        averageWPM = d.double(forKey: Keys.average)
        bestWPM = d.double(forKey: Keys.best)
        sampleCount = d.integer(forKey: Keys.count)
    }

    /// Record one dictation's pace from its final text and the time spent
    /// speaking. Call AFTER the text is written. Implausible inputs (too short,
    /// no words, or an absurd rate) are ignored so a stray tap can't skew the
    /// average.
    func record(text: String, seconds: TimeInterval) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 0, seconds >= 0.5 else { return }
        let wpm = Double(words) / (seconds / 60.0)
        guard wpm.isFinite, wpm > 0, wpm < 600 else { return }

        lastWPM = wpm
        bestWPM = max(bestWPM, wpm)
        averageWPM = sampleCount == 0
            ? wpm
            : (averageWPM * Double(sampleCount) + wpm) / Double(sampleCount + 1)
        sampleCount += 1
        persist()
    }

    func reset() {
        lastWPM = 0; averageWPM = 0; bestWPM = 0; sampleCount = 0
        persist()
    }

    /// Where a given pace sits among speakers, as a percentile (1…99). Models
    /// conversational speaking rate as a normal distribution (mean ~130 WPM,
    /// SD ~30 — typical for English speech), so e.g. 160 WPM ≈ 84th percentile.
    /// Returns "you speak faster than N% of people".
    static func percentile(forWPM wpm: Double) -> Int {
        guard wpm > 0 else { return 0 }
        let mean = 130.0, sd = 30.0
        let z = (wpm - mean) / (sd * 2.0.squareRoot())
        let cdf = 0.5 * (1 + erf(z))               // normal CDF
        return min(99, max(1, Int((cdf * 100).rounded())))
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(lastWPM, forKey: Keys.last)
        d.set(averageWPM, forKey: Keys.average)
        d.set(bestWPM, forKey: Keys.best)
        d.set(sampleCount, forKey: Keys.count)
    }
}
