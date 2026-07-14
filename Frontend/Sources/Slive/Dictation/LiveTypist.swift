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

    // Queue-isolated state.
    private var committed = ""     // exactly what we've typed into the field
    private var target = ""        // what we're typing toward
    private var running = false
    private var enabled = false    // false → no editable field, so never post keys

    /// Begin a session. `allowed` (from `PasteEngine.canStreamType()`, checked on
    /// the main thread) gates whether we actually post keystrokes this session.
    func start(allowed: Bool) {
        queue.async {
            self.committed = ""
            self.target = ""
            self.enabled = allowed
            self.running = true
            self.tick()
        }
    }

    /// Update the text we're easing toward.
    func setTarget(_ text: String) {
        queue.async { self.target = text }
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

        // Adapt cadence to how far behind we are: drain bursts quickly, ease when
        // close so it reads as smooth continuous typing.
        let backlog = abs(target.count - committed.count)
        let delay: TimeInterval
        switch backlog {
        case 0:            delay = 0.030   // idle poll for the next target
        case 1...5:        delay = 0.035   // ~28 cps — the smooth cruising speed
        case 6...11:       delay = 0.020
        default:           delay = 0.010   // far behind → catch up fast
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
