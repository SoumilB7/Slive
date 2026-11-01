import Foundation

struct TimeoutError: Error {}
/// A download that made no progress for the watchdog's window.
struct StallError: Error {}

/// Stamped by a download's progress callback (any thread); read by its
/// stall watchdog.
final class ProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    func tick() { lock.lock(); last = Date(); lock.unlock() }
    var idleSeconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}

/// Resumes a continuation exactly once, from whichever side finishes first.
private final class TimeoutRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    /// Resume the caller with `result` — true only for the first finisher.
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

/// Run `operation`, failing with `TimeoutError` if it doesn't finish in time.
///
/// Races an UNSTRUCTURED task against the timer. A task group can't do this:
/// it waits for every child before returning, and WhisperKit's `loadModels` /
/// FluidAudio's `AsrModels.load` ignore cancellation — so a hung Neural
/// Engine compile held the 600s "timeout" open forever (status stuck on
/// Preparing, every dictation waiting on the load never typed).
///
/// On timeout the operation is abandoned, not stopped (it can't be), and a
/// result that arrives later is DISCARDED: the app already reported the
/// failure, a retry may be under way, and Re-download may have deleted the
/// files it loaded. The retry is cheap by then — the compile it finished is
/// cached by the OS.
///
/// Decodes and warm-ups use it too: a Core ML predict that never returns
/// held `beginDecode` (and every dictation queued behind it) forever.
func withTimeout<T>(seconds: UInt64, what: String = "model load",
                    _ operation: @escaping () async throws -> T) async throws -> T {
    try await race(what: what, operation) { race in
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        if !Task.isCancelled { _ = race.finish(.failure(TimeoutError())) }
    }
}

/// Run a download, failing with `StallError` once `clock` hasn't ticked for
/// `seconds`. Neither HubApi nor FluidAudio can be cancelled mid-file and a
/// dead connection doesn't always error — Settings sat on "Downloading 37%"
/// forever. Same abandon-don't-stop race as `withTimeout`; a late finisher's
/// files are kept (the next download resumes from them).
func withStallWatchdog<T>(seconds: TimeInterval, clock: ProgressClock,
                          _ operation: @escaping () async throws -> T) async throws -> T {
    try await race(what: "download", operation) { race in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled, clock.idleSeconds > seconds { _ = race.finish(.failure(StallError())); return }
        }
    }
}

/// `operation` against `watchdog` (which fails the race when it fires); the
/// watchdog is cancelled once the operation finishes.
private func race<T>(what: String, _ operation: @escaping () async throws -> T,
                     watchdog: @escaping (TimeoutRace<T>) async -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let race = TimeoutRace(continuation)
        let timer = Task { await watchdog(race) }
        Task {
            do {
                let value = try await operation()
                timer.cancel()
                if !race.finish(.success(value)) {
                    Log.event("\(what) finished after its timeout — result discarded")
                }
            } catch {
                timer.cancel()
                _ = race.finish(.failure(error))
            }
        }
    }
}
