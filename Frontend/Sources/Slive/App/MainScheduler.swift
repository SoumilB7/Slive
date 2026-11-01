import Foundation

/// One-shot main-queue timers (the hold arm, the release tail, the overlay's
/// collapse / stuck / hide-soon) plus the clock they're measured on. The app
/// runs on `DispatchQueue.main.asyncAfter` exactly as before; the self-tests
/// drive a manual clock so the gesture and overlay rules run without
/// hardware or real waits.
@MainActor protocol MainScheduler: AnyObject {
    var now: Date { get }
    /// Run `work` on the main queue after `seconds`. Cancel the returned
    /// item and it never runs.
    @discardableResult
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> DispatchWorkItem
}

/// Production scheduler: a `DispatchWorkItem` on the main queue at
/// `.now() + seconds`, the same call every timer here used inline.
final class DispatchMainScheduler {
    static let shared = DispatchMainScheduler()

    var now: Date { Date() }

    @discardableResult
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem { MainActor.assumeIsolated(work) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
}

/// Declared apart so the class stays nonisolated (usable as a default argument).
extension DispatchMainScheduler: MainScheduler {}
