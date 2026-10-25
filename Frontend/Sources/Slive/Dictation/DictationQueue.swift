import Foundation

/// Dictations released while the speech model was still loading (launch, a
/// purged Neural Engine cache, Feather's idle unload). They type in the order
/// they were spoken: each waits for its turn, and finishing one — typed, empty
/// or failed — hands the turn to the next. Oct 28–29: a newer hold cancelled
/// the waiting ones and the words were lost.
@MainActor final class DictationQueue {
    private var order: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    var isEmpty: Bool { order.isEmpty }
    var count: Int { order.count }

    /// Join the back of the queue.
    func enqueue() -> UUID {
        let id = UUID()
        order.append(id)
        return id
    }

    /// `id` is the oldest queued dictation — it may type now.
    func isTurn(_ id: UUID) -> Bool { order.first == id }

    /// `id` is the newest queued dictation — the "Preparing" box is its own.
    func isLast(_ id: UUID) -> Bool { order.last == id }

    /// Suspend until every older dictation has finished.
    func turn(_ id: UUID) async {
        guard order.contains(id), !isTurn(id) else { return }
        await withCheckedContinuation { waiting[id] = $0 }
    }

    /// `id` is done (or gone): drop it and wake the next in line.
    func finish(_ id: UUID) {
        order.removeAll { $0 == id }
        waiting.removeValue(forKey: id)?.resume()
        if let next = order.first, let resume = waiting.removeValue(forKey: next) { resume.resume() }
    }
}
