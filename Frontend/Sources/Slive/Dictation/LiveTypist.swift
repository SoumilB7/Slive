import Foundation

/// Types text into the focused field toward a moving target as continuous
/// dictation is recognised. Two motions are deliberately separated:
///
///  - **Forward reveal** — brand-new characters appear one at a time at the
///    user's chosen speed (`cps`), so new text types out at a steady, readable
///    pace.
///  - **Corrections** — when the recogniser revises a word that's already been
///    typed, the backspace-and-retype happens **instantly** (in a single step),
///    so you don't see characters slowly changing under the cursor while you
///    speak (which is distracting).
///
/// This is done with a paced *frontier*: `revealed` (how many characters of the
/// current target we've committed to showing) advances at most one per tick at
/// `cps`, and every tick the field is snapped — instantly — to `target[0..<revealed]`.
/// So the leading edge moves at your speed while any change behind it just snaps.
///
/// A freeze boundary bounds corrections to the last `editableTail` characters, so
/// a late revision several sentences back can never cascade into a full rewrite.
///
/// All keystroke work runs on one private serial queue (so steps never interleave);
/// `setTarget` is safe to call from the main thread. `@unchecked Sendable`: all
/// mutable state is isolated to `queue`.
final class LiveTypist: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.slive.app.livetypist", qos: .userInitiated)

    /// Cadence at/above which we type "instantly" — the frontier jumps straight
    /// to the end each tick, so text just appears.
    private static let instantThreshold: Double = 120

    /// How many trailing characters stay editable. Text further back than this is
    /// "frozen" and never backspaced — so a late revision of a word several
    /// sentences back can't trigger a cascade that rewrites everything after it.
    private static let editableTail = 64

    // Queue-isolated state.
    private var committed = ""     // exactly what we've typed into the field
    private var target = ""        // what we're typing toward
    private var revealed = 0       // paced frontier: chars of `target` we're committing to show
    private var running = false
    private var enabled = false    // false → no editable field, so never post keys
    private var cps: Double = 30   // characters/sec the forward frontier advances
    private var instant = false    // cps >= instantThreshold → reveal everything at once
    private var frozenLen = 0      // committed[0..<frozenLen] is settled; never backspaced

    /// Begin a session. `allowed` (from `PasteEngine.canStreamType()`, checked on
    /// the main thread) gates whether we actually post keystrokes this session.
    func start(allowed: Bool, cps: Double) {
        queue.async {
            self.committed = ""
            self.target = ""
            self.revealed = 0
            self.frozenLen = 0
            self.enabled = allowed
            self.cps = cps
            self.instant = cps >= Self.instantThreshold
            self.running = true
            self.tick()
        }
    }

    /// Move the goal. The tick loop reveals/reconciles toward it.
    func setTarget(_ text: String) {
        queue.async { self.target = text }
    }

    /// Stop pacing, snap the field to the full final target at once, and return it.
    func finish() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                self.running = false
                if self.enabled {
                    self.revealed = self.target.count
                    self.reconcile(to: Array(self.target))
                }
                let result = self.committed
                self.committed = ""; self.target = ""; self.revealed = 0; self.frozenLen = 0
                continuation.resume(returning: result)
            }
        }
    }

    /// Abort with no further typing (quit / dismiss).
    func cancel() {
        queue.async {
            self.running = false
            self.committed = ""; self.target = ""; self.revealed = 0; self.frozenLen = 0
        }
    }

    // MARK: - Paced loop (queue only)

    private func tick() {
        guard running else { return }

        var delay: TimeInterval = 0.030   // idle poll when caught up
        if enabled {
            let t = Array(target)
            if revealed > t.count { revealed = t.count }      // target shrank (a revision)
            if instant {
                revealed = t.count                            // reveal all at once
            } else if revealed < t.count {
                revealed += 1                                 // reveal one more char (paced)
            }
            // Snap the field to the first `revealed` chars — INSTANTLY. New text
            // therefore appears at `cps` (frontier advance), while any correction
            // behind the frontier is applied in one step, not animated.
            reconcile(to: Array(t.prefix(revealed)))

            let remaining = t.count - revealed
            delay = remaining <= 0 ? 0.030 : forwardDelay(remaining: remaining)
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tick() }
    }

    /// Make the field exactly match `desired` in a single instant step: backspace
    /// the divergent tail, then type the corrected remainder as one keystroke.
    /// Respects the freeze boundary (never backspaces below `frozenLen`), so deep
    /// revisions can't cascade. A pure forward step (desired = committed + 1 char)
    /// is just that one appended character.
    private func reconcile(to desired: [Character]) {
        let old = Array(committed)
        let lo = min(frozenLen, old.count, desired.count)
        var common = lo
        let maxCommon = min(old.count, desired.count)
        while common < maxCommon && old[common] == desired[common] { common += 1 }

        let keep = max(common, min(frozenLen, old.count))
        let deletes = old.count - keep
        guard deletes > 0 || desired.count > keep else { return }   // nothing changed

        for _ in 0..<deletes { PasteEngine.postBackspace() }        // instant
        let insert = desired.count > keep ? String(desired[keep...]) : ""
        if !insert.isEmpty { PasteEngine.postUnicode(insert) }      // one event → instant
        // `committed` mirrors the FIELD: kept (old) prefix + what we just typed.
        committed = String(old[0..<keep]) + insert
        frozenLen = max(frozenLen, committed.count - Self.editableTail)
    }

    /// Delay before revealing the next NEW character. Cruises at the chosen `cps`,
    /// but shrinks toward a fast floor when far behind so the frontier never lags
    /// unbounded; a gentle ceiling keeps the tail from crawling.
    private func forwardDelay(remaining: Int) -> TimeInterval {
        Self.forwardDelay(remaining: remaining, cps: cps)
    }

    /// Pure pacing math, split out so tests can pin its bounds. Same formula as
    /// always: cruise at `cps`, shrink toward the floor when far behind, ceiling
    /// so the tail never crawls.
    static func forwardDelay(remaining: Int, cps: Double) -> TimeInterval {
        let spread = min(1.5, max(0.35, 30.0 / max(cps, 1)))
        let fastest = cps > 0 ? 1.0 / cps : 0.033
        let slowest = 0.10
        return min(slowest, max(fastest, spread / Double(remaining)))
    }
}
