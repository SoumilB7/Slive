import SliveCore

/// The queue rule per action — here because actions (and their specs) are
/// app-side; the queue itself is pure and lives in SliveCore.
extension DictationQueue {
    /// Does a release join the queue? Every dictation does, model ready or
    /// not — Oct 29: released one, held the next within a second, and the
    /// first was "cancelled after decode", never typed. An assistant request
    /// joins only behind a loading model or dictations still in line;
    /// otherwise a newer hold (or ✕) may still supersede it.
    static func queues(_ action: HotkeyAction, modelReady: Bool, queueEmpty: Bool) -> Bool {
        action.spec.alwaysQueues || !modelReady || !queueEmpty
    }
}
