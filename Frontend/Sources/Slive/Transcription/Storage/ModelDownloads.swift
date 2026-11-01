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

    init(basket: ModelBasket, board: ModelStatusBoard, stallSeconds: TimeInterval = defaultStallSeconds) {
        self.basket = basket
        self.board = board
        self.stallSeconds = stallSeconds
    }

    func isRunning(_ model: String) -> Bool { tasks[model] != nil }

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
        board.setStatus(.downloading(0), for: model)
        let task = Task { () -> Bool in
            let ok = await self.perform(model, storage)
            self.tasks[model] = nil
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
        do {
            let folder = try await withStallWatchdog(seconds: stallSeconds, clock: clock) {
                try await storage.fetch(model, progress: progress)
            }
            if let folder { basket.stampComplete(folder) }
            try? FileManager.default.removeItem(at: pending)
            board.setStatus(.ready, for: model)   // on disk, one select away (see `refreshStatus`)
            return true
        } catch is StallError {
            Log.event("download of \(model) stalled — no progress for \(Int(stallSeconds))s")
            board.setStatus(.failed("Download stalled. Check your connection."), for: model)
        } catch {
            board.setStatus(.failed("Download failed: \(error.localizedDescription)"), for: model)
        }
        return false
    }
}
