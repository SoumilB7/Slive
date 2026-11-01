import Foundation

/// Word-level diff between what Slive transcribed and the ground truth, so the
/// Training table can highlight exactly the corrected words instead of painting
/// the whole string orange. Pure logic — covered by `SliveSelfTest`.
public enum TranscriptDiff {
    /// Above this many words on either side, fall back to whole-string styling.
    /// Long-form dictations run to several hundred words — a cap they actually
    /// hit painted whole rows orange and read as a broken diff. 600² Int32
    /// cells is ~1.4 MB, computed once per sample (memoized by the app's
    /// TranscriptDiffCache).
    public static let maxWords = 600

    public static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// For each word of `truth`, whether it is part of the longest common
    /// subsequence with `output` (true = unchanged, false = a correction).
    public static func matchMask(output: [String], truth: [String]) -> [Bool] {
        diff(output: output, truth: truth).mask
    }

    /// Full word diff: the truth-side match mask, plus the truth indices
    /// where output words were DELETED (a deletion before `truth[j]` reports
    /// site `j`; a deletion after the last word reports `truth.count`).
    /// Deletions have no truth word to color — the sites let the renderer
    /// underline the neighbor instead of giving up on the whole string.
    public static func diff(output: [String], truth: [String])
        -> (mask: [Bool], deletionSites: Set<Int>) {
        let n = output.count, m = truth.count
        guard n > 0, m > 0 else {
            return ([Bool](repeating: false, count: m), n > 0 ? [0] : [])
        }
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
        // Walk back: mark truth words on the common subsequence, and note
        // where output-side words fell out entirely.
        var mask = [Bool](repeating: false, count: m)
        var deletions = Set<Int>()
        var i = n, j = m
        while i > 0 && j > 0 {
            if output[i - 1] == truth[j - 1] {
                mask[j - 1] = true
                i -= 1; j -= 1
            } else if dp[(i - 1) * stride + j] >= dp[i * stride + (j - 1)] {
                deletions.insert(j)   // output[i-1] deleted before truth[j]
                i -= 1
            } else {
                j -= 1
            }
        }
        if i > 0 { deletions.insert(0) }   // leading output words deleted
        return (mask, deletions)
    }

    /// How far apart the pair is, word-level: 1 − LCS / max(word count) —
    /// 0 = identical, 1 = nothing in common. Above ~0.5 the "correction" is
    /// usually not a correction at all (the model answered, drifted, or got
    /// different audio) and deserves a human look.
    public static func divergence(output: String, truth: String) -> Double {
        let out = words(output)
        let tru = words(truth)
        if out.isEmpty && tru.isEmpty { return 0 }
        guard !out.isEmpty, !tru.isEmpty else { return 1 }
        // Too big to judge cheaply — don't flag rather than guess.
        guard out.count <= maxWords, tru.count <= maxWords else { return 0 }
        let common = matchMask(output: out, truth: tru).lazy.filter { $0 }.count
        return 1 - Double(common) / Double(max(out.count, tru.count))
    }
}
