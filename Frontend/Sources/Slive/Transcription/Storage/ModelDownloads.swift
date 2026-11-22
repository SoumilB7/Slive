import Foundation

/// Downloads, for every engine: the unfinished-download marker, one download
/// per model, the stall watchdog, and the status the pickers show.
@MainActor
final class ModelDownloads {
    /// No progress for this long fails the download.
    nonisolated static let defaultStallSeconds: TimeInterval = 60

    let basket: ModelBasket
    private let stallSeconds: TimeInterval
    private unowned let board: ModelStatusBoard
    /// The one in-flight download per model: Turn on, Download and the
    /// continuous auto-fetch all join it instead of racing a second copy.
    private var tasks: [String: Task<Bool, Never>] = [:]
    /// Each download's end, once (not once per joined caller): the model and
    /// whether its files landed. ModelResidency counts the dictation pick's
    /// failures.
    var onFinished: ((_ model: String, _ ok: Bool) -> Void)?

    /// Fetches the stall watchdog gave up on. They can't be stopped mid-file
    /// and may still be writing into the model's folder, so nothing deletes
    /// those files or fetches again until one has ended.
    private var abandoned: [String: (fetch: Task<URL?, Error>, ended: Task<Void, Never>)] = [:]
    /// How long Re-download waits for an abandoned fetch before giving up.
    private let abandonedWaitSeconds: TimeInterval
    nonisolated static let stoppingStatus = ModelStatus.preparing("Stopping old download")

    init(basket: ModelBasket, board: ModelStatusBoard, stallSeconds: TimeInterval = defaultStallSeconds,
         abandonedWaitSeconds: TimeInterval = 120) {
        self.basket = basket
        self.board = board
        self.stallSeconds = stallSeconds
        self.abandonedWaitSeconds = abandonedWaitSeconds
    }

    func isRunning(_ model: String) -> Bool { tasks[model] != nil }

    /// Let `model`'s abandoned fetch, if any, end first: cancel it and wait.
    /// False (and the status says so) when it's still running after the wait.
    func settleAbandoned(_ model: String) async -> Bool {
        guard let old = abandoned[model] else { return true }
        old.fetch.cancel()
        board.setStatus(Self.stoppingStatus, for: model)
        let deadline = Date().addingTimeInterval(abandonedWaitSeconds)
        while abandoned[model] != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard abandoned[model] == nil else {
            Log.event("abandoned download of \(model) still running — not starting another")
            board.setStatus(.failed("Old download still running. Try again shortly."), for: model)
            return false
        }
        return true
    }

    private func abandon(_ fetch: Task<URL?, Error>, for model: String) {
        let ended = Task { [weak self] in
            _ = try? await fetch.value
            self?.abandoned[model] = nil
            Log.event("abandoned download of \(model) ended")
        }
        abandoned[model] = (fetch, ended)
    }

    /// Available without a download — bundled, installed OR on disk.
    func isDownloaded(_ model: String, in storage: ModelStorage) -> Bool {
        // A download that hasn't finished (still running, stalled, or the app
        // quit mid-way) leaves its marker: its folder may already hold an
        // AudioEncoder, which once made a partial download look complete.
        if FileManager.default.fileExists(atPath: basket.pendingMarker(model).path) { return false }
        return storage.hasFiles(model)
    }

    /// Download `model` if it isn't on disk (no load). True when it is.
    func fetch(_ model: String, into storage: ModelStorage) async -> Bool {
        if let running = tasks[model] { return await running.value }
        if isDownloaded(model, in: storage) { return true }
        guard await settleAbandoned(model) else { return false }
        // Another caller may have started it while this one waited.
        if let running = tasks[model] { return await running.value }
        board.setStatus(.downloading(0), for: model)
        let task = Task { () -> Bool in
            let ok = await self.perform(model, storage)
            self.tasks[model] = nil
            self.onFinished?(model, ok)
            return ok
        }
        tasks[model] = task
        return await task.value
    }

    private func perform(_ model: String, _ storage: ModelStorage) async -> Bool {
        let pending = basket.pendingMarker(model)
        FileManager.default.createFile(atPath: pending.path, contents: nil)
        let clock = ProgressClock()
        // A late progress tick must not drag a failed or loading model back
        // to "Downloading".
        let progress = DownloadProgress(
            report: { [weak self] fraction in
                clock.tick()
                Task { @MainActor in
                    guard let self, case .downloading = self.board.status(for: model) else { return }
                    self.board.setStatus(.downloading(fraction), for: model)
                }
            },
            alive: { clock.tick() })
        // Our own handle on the fetch, so a stalled one can be tracked to its end.
        let fetch = Task { try await storage.fetch(model, progress: progress) }
        do {
            let folder = try await withStallWatchdog(seconds: stallSeconds, clock: clock) {
                try await fetch.value
            }
            if let folder { basket.stampComplete(folder) }
            try? FileManager.default.removeItem(at: pending)
            board.setStatus(.ready, for: model)   // on disk, one select away (see `refreshStatus`)
            return true
        } catch is StallError {
            abandon(fetch, for: model)
            Log.event("download of \(model) stalled — no progress for \(Int(stallSeconds))s")
            board.setStatus(.failed("Download stalled. Check your connection."), for: model)
        } catch {
            board.setStatus(.failed("Download failed: \(error.localizedDescription)"), for: model)
        }
        return false
    }
}
