import Foundation

/// Types text into the focused field one keystroke at a time toward a moving
/// target, so live dictation reads as smooth character-by-character typing
/// instead of ~3 words appearing at once each time the recogniser passes.
///
/// The recogniser and the typist are decoupled: `setTarget` just moves the goal,
/// and a paced loop walks the field toward it a single key at a time — typing a
/// character when behind, backspacing when the tail was revised. Pacing adapts to
/// the backlog: it speeds up to drain a burst and eases near the target, so it
/// stays continuous and never falls far behind speech.
///
/// All keystroke work runs on one private serial queue (so steps never interleave);
/// `setTarget` is safe to call from the main thread.
/// `@unchecked Sendable`: all mutable state is isolated to `queue` (a serial
/// queue), so it's only ever touched from one thread at a time.
final class LiveTypist: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.slive.app.livetypist", qos: .userInitiated)

    /// Cadence at/above which we type "instantly": don't pace at all, just flush the
    /// whole remaining diff on each `setTarget` so text appears at once.
    private static let instantThreshold: Double = 120

    /// How many trailing characters stay editable. Text further back than this is
    /// "frozen" and never backspaced — so a late revision of a word several
    /// sentences back can't trigger a cascade that rewrites everything after it.
    /// Big enough to always cover the recogniser's live (unconfirmed) tail, so
    /// normal corrections are untouched; only DEEP revisions are refused.
    private static let editableTail = 64

    // Queue-isolated state.
    private var committed = ""     // exactly what we've typed into the field
    private var target = ""        // what we're typing toward
    private var running = false
    private var enabled = false    // false → no editable field, so never post keys
    private var cps: Double = 30   // characters/sec cruising speed for this session
    private var instant = false    // cps >= instantThreshold → flush whole diff
    private var frozenLen = 0      // committed[0..<frozenLen] is settled; never backspaced

    /// Begin a session. `allowed` (from `PasteEngine.canStreamType()`, checked on
    /// the main thread) gates whether we actually post keystrokes this session.
    /// `cps` is the cruising characters-per-second; `>= 120` means "Instant" (each
    /// `setTarget` flushes the whole remaining diff immediately, no paced loop).
    func start(allowed: Bool, cps: Double) {
        queue.async {
            self.committed = ""
            self.target = ""
            self.frozenLen = 0
            self.enabled = allowed
            self.cps = cps
            self.instant = cps >= Self.instantThreshold
            self.running = true
            // Instant mode has no paced loop — `setTarget` does all the work.
            if !self.instant { self.tick() }
        }
    }

    /// Update the text we're easing toward. In Instant mode, flush the whole
    /// remaining diff right away so the text lands at once.
    func setTarget(_ text: String) {
        queue.async {
            self.target = text
            if self.instant, self.running, self.enabled { self.flushRemaining() }
        }
    }

    /// Stop pacing, immediately flush whatever's left so the field matches the
    /// last target, and return the final typed text.
    func finish() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                self.running = false
                if self.enabled { self.flushRemaining() }
                let result = self.committed
                self.committed = ""
                self.target = ""
                continuation.resume(returning: result)
            }
        }
    }

    /// Abort with no further typing (quit / dismiss).
    func cancel() {
        queue.async {
            self.running = false
            self.committed = ""
            self.target = ""
        }
    }

    // MARK: - Paced loop (queue only)

    /// The recogniser delivers text in ~1s chunks, so a whole word or three lands
    /// at once. To read as SMOOTH continuous typing (not a fast burst then a
    /// pause), we spread the remaining characters evenly across roughly one chunk
    /// interval: each forward keystroke's delay = `spread / charsRemaining`,
    /// clamped so it never types faster than the chosen speed nor slower than a
    /// gentle floor. Backspacing (correcting a revised tail) stays snappy so a
    /// wrong word is undone quickly.
    private func tick() {
        guard running else { return }

        var delay: TimeInterval = 0.030   // idle poll when caught up
        if enabled {
            let old = Array(committed), new = Array(target)
            // Reconcile only from the freeze boundary onward: treat everything
            // before it as agreed, so a deep revision can't backspace into it.
            let lo = min(frozenLen, old.count, new.count)
            var common = lo
            let maxCommon = min(old.count, new.count)
            while common < maxCommon && old[common] == new[common] { common += 1 }

            if old.count > common && committed.count > frozenLen {
                // Wrong tail character (within the editable window) → backspace it
                // quickly. Never dips below frozenLen.
                PasteEngine.postBackspace()
                committed.removeLast()
                delay = 0.012
            } else if new.count > common {
                // Type the next character, paced to spread the remaining run
                // smoothly over ~one chunk interval.
                PasteEngine.postUnicode(String(new[common]))
                committed.append(new[common])
                // Settle everything but the last `editableTail` chars.
                frozenLen = max(frozenLen, committed.count - Self.editableTail)
                let remaining = new.count - committed.count
                delay = remaining <= 0 ? 0.030 : forwardDelay(remaining: remaining)
            }
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tick() }
    }

    /// Per-keystroke delay that spreads `remaining` characters evenly over a
    /// window, so a whole chunk types continuously instead of bursting. The chosen
    /// `cps` scales the window (higher = drains faster) AND caps the top rate; a
    /// gentle floor keeps the tail from crawling.
    private func forwardDelay(remaining: Int) -> TimeInterval {
        let spread = min(1.5, max(0.35, 30.0 / max(cps, 1)))   // window ≈ one chunk at 30 cps
        let fastest = cps > 0 ? 1.0 / cps : 0.033              // chosen speed caps the rate
        let slowest = 0.10                                     // ~10 cps floor so it never crawls
        return min(slowest, max(fastest, spread / Double(remaining)))
    }

    /// Apply the entire remaining diff at once (used on release / Instant so the
    /// field is correct promptly). Also respects the freeze boundary: it never
    /// backspaces below `frozenLen`, so even the final full-accuracy pass can't
    /// rewrite sentences the user has long since moved past — it only reconciles
    /// the editable tail and appends what's new.
    private func flushRemaining() {
        let old = Array(committed), new = Array(target)
        let lo = min(frozenLen, old.count, new.count)
        var common = lo
        let maxCommon = min(old.count, new.count)
        while common < maxCommon && old[common] == new[common] { common += 1 }

        // Never backspace below the freeze boundary (guards the rare case where the
        // target is shorter than it). `keep` is where the field stays unchanged.
        let keep = max(common, min(frozenLen, old.count))
        for _ in 0..<(old.count - keep) { PasteEngine.postBackspace() }
        let insert = new.count > keep ? String(new[keep...]) : ""
        if !insert.isEmpty { PasteEngine.postUnicode(insert) }
        // `committed` mirrors the FIELD: the kept (old) prefix + what we just typed.
        committed = String(old[0..<keep]) + insert
        frozenLen = max(frozenLen, committed.count - Self.editableTail)
    }
}
