import Foundation

/// Released dictations — including those released while the speech model was
/// still loading (launch, a purged Neural Engine cache, Feather's idle
/// unload). They type in the order they were spoken: each waits for its turn,
/// and finishing one — typed, empty or failed — hands the turn to the next.
/// Oct 28–29: a newer hold cancelled the waiting ones and the words were lost.
@MainActor public final class DictationQueue {
    private var order: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Each queued release's decode-and-type task (cancelled only on quit,
    /// or ✕ for an assistant request).
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// The queued entries that are assistant requests — ✕ drops those (an
    /// answer isn't spoken words; dictations still type).
    private var assists: Set<UUID> = []

    public init() {}

    public var isEmpty: Bool { order.isEmpty }
    public var count: Int { order.count }

    /// Join the back of the queue.
    public func enqueue() -> UUID {
        let id = UUID()
        order.append(id)
        return id
    }

    /// `id` is the oldest queued dictation — it may type now.
    public func isTurn(_ id: UUID) -> Bool { order.first == id }

    /// `id` is the newest queued dictation — the "Preparing" box is its own.
    public func isLast(_ id: UUID) -> Bool { order.last == id }

    /// Suspend until every older dictation has finished.
    public func turn(_ id: UUID) async {
        guard order.contains(id), !isTurn(id) else { return }
        await withCheckedContinuation { waiting[id] = $0 }
    }

    /// `id` is done (or gone): drop it and wake the next in line. Safe to
    /// repeat — a queued assistant hands its turn on early.
    public func finish(_ id: UUID) {
        order.removeAll { $0 == id }
        tasks[id] = nil
        assists.remove(id)
        waiting.removeValue(forKey: id)?.resume()
        if let next = order.first, let resume = waiting.removeValue(forKey: next) { resume.resume() }
    }

    /// The task that decodes and types `id` (`isAssist`: an assistant request).
    public func track(_ task: Task<Void, Never>, for id: UUID, isAssist: Bool) {
        tasks[id] = task
        if isAssist { assists.insert(id) }
    }

    /// A queued assistant request has its question: it leaves the queue and
    /// its task becomes the ordinary in-flight answer (returned).
    public func handOff(_ id: UUID) -> Task<Void, Never>? {
        let task = tasks[id]
        finish(id)
        return task
    }

    /// ✕: drop the waiting assistant requests; dictations still type.
    public func cancelAssists() {
        for id in assists { tasks[id]?.cancel() }
    }

    /// Quit.
    public func cancelAll() {
        tasks.values.forEach { $0.cancel() }
    }
}
