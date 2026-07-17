import SwiftUI

/// Word-level diff between what Slive transcribed and the ground truth, so the
/// Training table can highlight exactly the corrected words instead of painting
/// the whole string orange. Pure logic — covered by `--self-test`.
enum TranscriptDiff {
    /// Above this many words on either side, fall back to whole-string styling
    /// (quadratic LCS not worth it and the row is unreadable anyway).
    static let maxWords = 200

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// For each word of `truth`, whether it is part of the longest common
    /// subsequence with `output` (true = unchanged, false = a correction).
    static func matchMask(output: [String], truth: [String]) -> [Bool] {
        let n = output.count, m = truth.count
        guard n > 0, m > 0 else { return [Bool](repeating: false, count: m) }
        // LCS length table (n+1)×(m+1).
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                dp[i][j] = output[i - 1] == truth[j - 1]
                    ? dp[i - 1][j - 1] + 1
                    : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        // Walk back, marking truth words that are on the common subsequence.
        var mask = [Bool](repeating: false, count: m)
        var i = n, j = m
        while i > 0 && j > 0 {
            if output[i - 1] == truth[j - 1] {
                mask[j - 1] = true
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return mask
    }

    /// The ground-truth string with corrected words emphasized, or nil when
    /// either side exceeds `maxWords` (caller falls back to whole-string color).
    static func attributed(output: String, truth: String,
                           base: Color, changed: Color) -> AttributedString? {
        let out = words(output)
        let tru = words(truth)
        guard out.count <= maxWords, tru.count <= maxWords else { return nil }
        let mask = matchMask(output: out, truth: tru)
        var result = AttributedString()
        for (index, word) in tru.enumerated() {
            var piece = AttributedString(word)
            if mask[index] {
                piece.foregroundColor = base
            } else {
                piece.foregroundColor = changed
                piece.font = SliveTheme.font(12, .semibold)
            }
            result += piece
            if index < tru.count - 1 { result += AttributedString(" ") }
        }
        return result
    }
}
