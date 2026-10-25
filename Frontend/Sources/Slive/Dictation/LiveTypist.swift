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
    private var pendingTick: DispatchWorkItem?   // the scheduled next tick
    private var waitingIdle = false              // that tick is just the idle poll
    /// The field this session types into, re-checked before keystrokes (nil =
    /// unguarded). Once focus leaves it, nothing more is typed or deleted.
    private var focusTarget: PasteEngine.StreamTarget?
    private var focusLost = false
    private var lastFocusCheck = Date.distantPast

    /// What a finished session left in the field, and whether focus moved
    /// away mid-session (then the caller should show the text instead).
    struct FinishResult {
        let text: String
        let focusLost: Bool
    }

    /// Begin a session. `allowed` (from `PasteEngine.canStreamType()`, checked on
    /// the main thread) gates whether we actually post keystrokes this session.
    func start(allowed: Bool, cps: Double, target: PasteEngine.StreamTarget? = nil) {
        queue.async {
            self.committed = ""
            self.target = ""
            self.revealed = 0
            self.frozenLen = 0
            self.focusTarget = target
            self.focusLost = false
            self.lastFocusCheck = .distantPast
            self.enabled = allowed
            self.cps = cps
            self.instant = cps >= Self.instantThreshold
            self.running = true
            self.tick()
        }
    }

    /// Move the goal. The tick loop reveals/reconciles toward it.
    func setTarget(_ text: String) {
        queue.async {
            self.target = text
            // Wake the loop NOW if it's just idle-polling — otherwise a freshly
            // recognised word waits up to 30ms before its first keystroke. A
            // mid-reveal (paced) delay is left alone so cps pacing stays exact.
            if self.running, self.waitingIdle {
                self.pendingTick?.cancel()
                self.tick()
            }
        }
    }

    /// Stop pacing, snap the field to the full final target at once, and return
    /// what's in the field.
    func finish() async -> FinishResult {
        await withCheckedContinuation { continuation in
            queue.async {
                self.running = false
                self.pendingTick?.cancel(); self.pendingTick = nil
                if self.enabled {
                    self.revealed = self.target.count
                    self.reconcile(to: Array(self.target))
                }
                let result = FinishResult(text: self.committed, focusLost: self.focusLost)
                self.committed = ""; self.target = ""; self.revealed = 0; self.frozenLen = 0
                self.focusTarget = nil; self.focusLost = false
                continuation.resume(returning: result)
            }
        }
    }

    /// Abort with no further typing (quit / dismiss).
    func cancel() {
        queue.async {
            self.running = false
            self.pendingTick?.cancel(); self.pendingTick = nil
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
            waitingIdle = remaining <= 0
        } else {
            waitingIdle = true
        }
        let item = DispatchWorkItem { [weak self] in self?.tick() }
        pendingTick = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Make the field exactly match `desired` in a single instant step: backspace
    /// the divergent tail, then type the corrected remainder as one keystroke.
    /// Respects the freeze boundary (never backspaces below `frozenLen`), so deep
    /// revisions can't cascade. A pure forward step (desired = committed + 1 char)
    /// is just that one appended character.
    private func reconcile(to desired: [Character]) {
        let old = Array(committed)
        let (keep, from) = Self.plan(old: old, desired: desired, frozen: frozenLen)
        let deletes = old.count - keep
        guard deletes > 0 || desired.count > from else { return }   // nothing changed
        guard focusStillOurs(deleting: deletes > 0) else { return }

        for _ in 0..<deletes { PasteEngine.postBackspace() }        // instant
        let insert = desired.count > from ? String(desired[from...]) : ""
        if !insert.isEmpty { PasteEngine.postUnicode(insert) }      // instant
        // `committed` mirrors the FIELD: kept (old) prefix + what we just typed.
        committed = String(old[0..<keep]) + insert
        frozenLen = max(frozenLen, committed.count - Self.editableTail)
    }

    /// The edit that moves the field (`old`) toward `desired` without touching
    /// its first `frozen` characters: keep `old[0..<keep]`, type `desired[from...]`.
    static func plan(old: [Character], desired: [Character], frozen: Int) -> (keep: Int, from: Int) {
        let f = min(frozen, old.count)
        let p = frozenAnchor(old: old, desired: desired, frozenEnd: f)
        var common = 0
        while f + common < old.count, p + common < desired.count,
              old[f + common] == desired[p + common] { common += 1 }
        return (f + common, p + common)
    }

    /// Where the field's frozen prefix `old[0..<f]` ends inside `desired`.
    /// Usually at `f`; after a revision BEHIND the freeze that changed its
    /// length ("a lot" → "allot"), the same text sits a few characters earlier
    /// or later — splicing `desired[f...]` there dropped or doubled a character
    /// at the seam, for good. Found by the frozen text's last few characters,
    /// nearest `f` first; unfindable → `f` (the old behaviour).
    static func frozenAnchor(old: [Character], desired: [Character], frozenEnd f: Int) -> Int {
        guard f > 0 else { return 0 }
        if f <= desired.count, old[0..<f].elementsEqual(desired[0..<f]) { return f }
        let w = min(16, f)
        let window = old[(f - w)..<f]
        for delta in 0...32 {
            for p in (delta == 0 ? [f] : [f - delta, f + delta])
            where p >= w && p <= desired.count && desired[(p - w)..<p].elementsEqual(window) {
                return p
            }
        }
        return min(f, desired.count)
    }

    /// Is keyboard focus still on this session's field? Checked before every
    /// delete and, for plain appends, at most every 150ms (AX reads cross into
    /// the target app). Focus was once checked only at start: switching apps
    /// mid-hold sent the corrections' backspaces into the new app.
    private func focusStillOurs(deleting: Bool) -> Bool {
        guard !focusLost else { return false }
        guard let focusTarget else { return true }
        let now = Date()
        if !deleting, now.timeIntervalSince(lastFocusCheck) < 0.15 { return true }
        lastFocusCheck = now
        if PasteEngine.isStillStreamTarget(focusTarget) { return true }
        focusLost = true
        enabled = false
        Log.live("focus left the field — typing stopped; the text goes to the copy box")
        return false
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
