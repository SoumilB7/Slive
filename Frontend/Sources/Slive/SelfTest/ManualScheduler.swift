import Foundation

/// A `MainScheduler` on a manual clock: `advance(by:)` runs whatever came
/// due, in time order (ties in scheduling order), including work scheduled
/// by work that ran.
@MainActor final class ManualScheduler: MainScheduler {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 0)
    private var pending: [(at: Date, seq: Int, item: DispatchWorkItem)] = []
    private var seq = 0

    @discardableResult
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem { MainActor.assumeIsolated(work) }
        seq += 1
        pending.append((now.addingTimeInterval(seconds), seq, item))
        return item
    }

    func advance(by seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = pending.filter({ $0.at <= end })
            .min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
            pending.removeAll { $0.seq == next.seq }
            now = max(now, next.at)
            if !next.item.isCancelled { next.item.perform() }
        }
        now = end
    }

    /// Timers still waiting to run.
    var waiting: Int { pending.filter { !$0.item.isCancelled }.count }

    /// The time of the earliest live timer, if any.
    var nextDue: Date? { pending.filter { !$0.item.isCancelled }.map(\.at).min() }

    /// Fire only the single earliest timer (ties in scheduling order),
    /// moving `now` to its time; false when none remain. A driver that must
    /// pump the Swift concurrency executor between timers (so async
    /// continuations resolve one chain at a time) steps with this instead of
    /// `advance(by:)`, which fires a whole batch without yielding.
    @discardableResult
    func advanceToNext() -> Bool {
        guard let next = pending.filter({ !$0.item.isCancelled })
            .min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) else { return false }
        pending.removeAll { $0.seq == next.seq }
        now = max(now, next.at)
        next.item.perform()
        return true
    }
}
