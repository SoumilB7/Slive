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

    // Queue-isolated state.
    private var committed = ""     // exactly what we've typed into the field
    private var target = ""        // what we're typing toward
    private var running = false
    private var enabled = false    // false → no editable field, so never post keys
    private var cps: Double = 30   // characters/sec cruising speed for this session
    private var instant = false    // cps >= instantThreshold → flush whole diff

    /// Begin a session. `allowed` (from `PasteEngine.canStreamType()`, checked on
    /// the main thread) gates whether we actually post keystrokes this session.
    /// `cps` is the cruising characters-per-second; `>= 120` means "Instant" (each
    /// `setTarget` flushes the whole remaining diff immediately, no paced loop).
    func start(allowed: Bool, cps: Double) {
        queue.async {
            self.committed = ""
            self.target = ""
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

    private func tick() {
        guard running else { return }
        if enabled, committed != target { stepOne() }

        // Cruise at 1/cps between keystrokes, but never lag unbounded: when far
        // behind, shrink the delay toward a fast ~0.008s floor so a burst drains
        // quickly, easing back to the cruise delay as we catch up.
        let cruise = cps > 0 ? 1.0 / cps : 0.035
        let floor = 0.008
        let backlog = abs(target.count - committed.count)
        let delay: TimeInterval
        switch backlog {
        case 0:
            delay = max(cruise, 0.030)     // idle poll for the next target
        case 1...5:
            delay = cruise                 // the smooth cruising speed
        default:
            // Scale from cruise (backlog 6) down to the floor (backlog ≥ 40).
            let t = min(1, Double(backlog - 6) / Double(40 - 6))
            delay = max(floor, cruise + (floor - cruise) * t)
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tick() }
    }

    /// Advance the field one keystroke toward `target`: keep the common prefix,
    /// then backspace an outdated tail character or type the next new one.
    private func stepOne() {
        let old = Array(committed), new = Array(target)
        var common = 0
        let maxCommon = min(old.count, new.count)
        while common < maxCommon && old[common] == new[common] { common += 1 }

        if old.count > common {
            PasteEngine.postBackspace()
            committed.removeLast()
        } else if new.count > common {
            let ch = new[common]
            PasteEngine.postUnicode(String(ch))
            committed.append(ch)
        }
    }

    /// Apply the entire remaining diff at once (used on release so the field is
    /// correct promptly rather than slowly finishing the tail).
    private func flushRemaining() {
        let old = Array(committed), new = Array(target)
        var common = 0
        let maxCommon = min(old.count, new.count)
        while common < maxCommon && old[common] == new[common] { common += 1 }

        for _ in 0..<(old.count - common) { PasteEngine.postBackspace() }
        let insert = String(new[common...])
        if !insert.isEmpty { PasteEngine.postUnicode(insert) }
        committed = target
    }
}
