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
        diff(output: output, truth: truth).mask
    }

    /// Full word diff: the truth-side match mask, plus the truth indices
    /// where output words were DELETED (a deletion before `truth[j]` reports
    /// site `j`; a deletion after the last word reports `truth.count`).
    /// Deletions have no truth word to color — the sites let the renderer
    /// underline the neighbor instead of giving up on the whole string.
    static func diff(output: [String], truth: [String])
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
    static func divergence(output: String, truth: String) -> Double {
        let out = words(output)
        let tru = words(truth)
        if out.isEmpty && tru.isEmpty { return 0 }
        guard !out.isEmpty, !tru.isEmpty else { return 1 }
        // Too big to judge cheaply — don't flag rather than guess.
        guard out.count <= maxWords, tru.count <= maxWords else { return 0 }
        let common = matchMask(output: out, truth: tru).lazy.filter { $0 }.count
        return 1 - Double(common) / Double(max(out.count, tru.count))
    }

    /// The ground-truth string with corrected words emphasized: replaced or
    /// new words in the changed color, and DELETIONS (output words the truth
    /// dropped — nothing truth-side to color) as a changed-color underline on
    /// the word right after the deletion site. The text itself stays verbatim
    /// (nothing inserted), so selection/copy is clean. nil only when either
    /// side exceeds `maxWords` — the caller falls back to whole-string
    /// coloring there.
    static func attributed(output: String, truth: String,
                           base: Color, changed: Color) -> AttributedString? {
        let out = words(output)
        let tru = words(truth)
        guard out.count <= maxWords, tru.count <= maxWords else { return nil }
        guard !tru.isEmpty else { return nil }
        let (mask, deletions) = diff(output: out, truth: tru)
        var result = AttributedString()
        for (index, word) in tru.enumerated() {
            var piece = AttributedString(word)
            if mask[index] {
                piece.foregroundColor = base
            } else {
                piece.foregroundColor = changed
                piece.font = SliveTheme.font(12, .semibold)
            }
            // A deletion before this word (or, for the final site, after the
            // last word) underlines the neighbor — one small mark instead of
            // the whole string turning orange for one dropped word.
            if deletions.contains(index)
                || (index == tru.count - 1 && deletions.contains(tru.count)) {
                piece.underlineStyle = .single
                piece.underlineColor = NSColor(changed)
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
    private static var offCache: [String: (truth: String, value: Double)] = [:]

    static func styled(id: String, output: String, truth: String,
                       base: Color, changed: Color) -> AttributedString? {
        if let hit = cache[id], hit.truth == truth { return hit.styled }
        let styled = TranscriptDiff.attributed(
            output: output, truth: truth, base: base, changed: changed)
        cache[id] = (truth, styled)
        return styled
    }

    /// Memoized `TranscriptDiff.divergence` — the table asks per row per
    /// render, and each ask is an LCS.
    static func divergence(id: String, output: String, truth: String) -> Double {
        if let hit = offCache[id], hit.truth == truth { return hit.value }
        let value = TranscriptDiff.divergence(output: output, truth: truth)
        offCache[id] = (truth, value)
        return value
    }

    static func clear() {
        cache.removeAll()
        offCache.removeAll()
    }

    static func remove(id: String) {
        cache.removeValue(forKey: id)
        offCache.removeValue(forKey: id)
    }
}
