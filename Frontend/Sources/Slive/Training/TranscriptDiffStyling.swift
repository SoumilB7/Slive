import SliveCore
import SwiftUI

/// The Training table's rendering of `TranscriptDiff` (SwiftUI colours and
/// fonts) — the diff itself is pure and lives in SliveCore.
extension TranscriptDiff {
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
        let between = gaps(truth)
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
            if index < tru.count - 1 { result += AttributedString(between[index]) }
        }
        return result
    }

    /// The whitespace between consecutive words of `text`, verbatim — so a
    /// formatted label's line breaks (list items, paragraphs) survive the
    /// diff instead of collapsing to spaces.
    static func gaps(_ text: String) -> [String] {
        var gaps = [String]()
        var gap = ""
        var seenWord = false
        for ch in text {
            if ch.isWhitespace {
                if seenWord { gap.append(ch) }
            } else {
                if seenWord, !gap.isEmpty { gaps.append(gap) }
                gap = ""
                seenWord = true
            }
        }
        return gaps
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
