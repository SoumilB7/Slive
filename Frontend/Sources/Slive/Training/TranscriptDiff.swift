import SwiftUI

/// Word-level diff between what Slive transcribed and the ground truth, so the
/// Training table can highlight exactly the corrected words instead of painting
/// the whole string orange. Pure logic — covered by `--self-test`.
enum TranscriptDiff {
    /// Above this many words on either side, fall back to whole-string styling.
    /// Long-form dictations run to several hundred words — a cap they actually
    /// hit painted whole rows orange and read as a broken diff. 600² Int32
    /// cells is ~1.4 MB, computed once per sample (memoized below).
    static let maxWords = 600

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// For each word of `truth`, whether it is part of the longest common
    /// subsequence with `output` (true = unchanged, false = a correction).
    static func matchMask(output: [String], truth: [String]) -> [Bool] {
        let n = output.count, m = truth.count
        guard n > 0, m > 0 else { return [Bool](repeating: false, count: m) }
        // LCS length table (n+1)×(m+1), flat Int32 — at the 600-word cap a
        // nested [[Int]] would transiently cost ~23 MB; this stays ~1.4 MB.
        let stride = m + 1
        var dp = [Int32](repeating: 0, count: (n + 1) * stride)
        for i in 1...n {
            for j in 1...m {
                dp[i * stride + j] = output[i - 1] == truth[j - 1]
                    ? dp[(i - 1) * stride + (j - 1)] + 1
                    : max(dp[(i - 1) * stride + j], dp[i * stride + (j - 1)])
            }
        }
        // Walk back, marking truth words that are on the common subsequence.
        var mask = [Bool](repeating: false, count: m)
        var i = n, j = m
        while i > 0 && j > 0 {
            if output[i - 1] == truth[j - 1] {
                mask[j - 1] = true
                i -= 1; j -= 1
            } else if dp[(i - 1) * stride + j] >= dp[i * stride + (j - 1)] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return mask
    }

    /// The ground-truth string with corrected words emphasized, or nil when the
    /// caller should fall back to whole-string coloring: either side exceeds
    /// `maxWords`, or the correction is a pure DELETION (output has extra words,
    /// every truth word matches — nothing truth-side to highlight, yet the pair
    /// differs; all-white here would read as "no correction").
    static func attributed(output: String, truth: String,
                           base: Color, changed: Color) -> AttributedString? {
        let out = words(output)
        let tru = words(truth)
        guard out.count <= maxWords, tru.count <= maxWords else { return nil }
        let mask = matchMask(output: out, truth: tru)
        if out != tru && !mask.contains(false) { return nil }
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

/// Row-render memo for the diff: the audio player republishes position at 10Hz
/// during playback, re-rendering every table row — without this each redraw
/// recomputes an up-to-200×200 LCS table per row. Keyed by sample id, validated
/// against the truth text (an id's transcript can only ever be set once, but
/// cheap to be safe). Main-actor only — touched exclusively from row rendering.
@MainActor
enum TranscriptDiffCache {
    /// `styled` may legitimately be nil (the whole-string fallback) — a
    /// dictionary hit distinguishes "cached nil" from "not computed yet".
    private static var cache: [String: (truth: String, styled: AttributedString?)] = [:]

    static func styled(id: String, output: String, truth: String,
                       base: Color, changed: Color) -> AttributedString? {
        if let hit = cache[id], hit.truth == truth { return hit.styled }
        let styled = TranscriptDiff.attributed(
            output: output, truth: truth, base: base, changed: changed)
        cache[id] = (truth, styled)
        return styled
    }

    static func clear() { cache.removeAll() }

    static func remove(id: String) { cache.removeValue(forKey: id) }
}
