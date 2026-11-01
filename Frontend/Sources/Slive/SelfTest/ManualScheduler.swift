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
}
