import Foundation

/// A single saved transcript. Immutable once created; `text` is already
/// trimmed and length-capped by `HistoryStore` before it lands here.
struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date

    /// When this entry ages out of the 24h catalogue.
    var expiresAt: Date { createdAt.addingTimeInterval(HistoryStore.ttl) }
}

/// A bounded, self-pruning catalogue of recent transcripts.
///
/// Storage can never explode: three independent guards keep it small —
/// a 24h TTL, a 200-entry cap, and a 2000-character cap per entry. Even a
/// burst of long dictations within the window stays under ~400 KB on disk.
///
/// Persisted as atomic JSON at
/// `~/Library/Application Support/Flowy/history.json`. Corrupt or missing
/// files degrade to an empty catalogue rather than crashing.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    // MARK: Bounds (storage must NEVER explode)

    /// Time-to-live for a transcript. Older entries are pruned everywhere.
    static let ttl: TimeInterval = 24 * 60 * 60          // 24 hours
    /// Hard ceiling on entry count. Bursts within the TTL still stay bounded.
    static let maxEntries = 200
    /// Per-entry text cap. One giant dictation can't blow up the file.
    static let maxTextLength = 2000
    /// How often the idle timer sweeps out expired entries.
    private static let pruneInterval: TimeInterval = 10 * 60   // 10 minutes

    // MARK: State

    @Published private(set) var entries: [HistoryEntry] = []

    /// Serialises all mutation + persistence off the main thread; `@Published`
    /// writes are always hopped back to main.
    private let queue = DispatchQueue(label: "com.flowy.history")
    private var pruneTimer: DispatchSourceTimer?

    private let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Flowy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")

        load()
        startPruneTimer()
    }

    // MARK: Public API

    /// Add a transcript. Empty/whitespace-only input is ignored. The text is
    /// trimmed and truncated, prepended (newest first), then the catalogue is
    /// pruned and persisted.
    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let capped = String(trimmed.prefix(Self.maxTextLength))
        let entry = HistoryEntry(id: UUID(), text: capped, createdAt: Date())

        queue.async {
            var next = self.entries
            next.insert(entry, at: 0)
            self.applyBounds(&next)
            self.persist(next)
            self.publish(next)
        }
    }

    /// Remove a single entry by id.
    func remove(_ id: UUID) {
        queue.async {
            var next = self.entries
            next.removeAll { $0.id == id }
            self.persist(next)
            self.publish(next)
        }
    }

    /// Drop everything.
    func clearAll() {
        queue.async {
            self.persist([])
            self.publish([])
        }
    }

    // MARK: Pruning + bounds

    /// Apply TTL then count cap. Order matters: expire first so the freshest
    /// 200 survive the count cap.
    private func applyBounds(_ list: inout [HistoryEntry]) {
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        list.removeAll { $0.createdAt < cutoff }
        if list.count > Self.maxEntries {
            list.removeLast(list.count - Self.maxEntries)
        }
    }

    private func startPruneTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pruneInterval,
                       repeating: Self.pruneInterval,
                       leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var next = self.entries
            let before = next.count
            self.applyBounds(&next)
            guard next.count != before else { return }   // nothing expired
            self.persist(next)
            self.publish(next)
        }
        timer.resume()
        pruneTimer = timer
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode([HistoryEntry].self, from: data) else {
            entries = []   // corrupt file -> start clean, never crash
            return
        }
        decoded.sort { $0.createdAt > $1.createdAt }   // newest first
        let rawCount = decoded.count
        applyBounds(&decoded)
        entries = decoded
        // If load-time pruning trimmed anything, rewrite the smaller file.
        if decoded.count != rawCount {
            let snapshot = decoded
            queue.async { self.persist(snapshot) }
        }
    }

    /// Atomic write. Never throws out to callers — persistence failures are
    /// logged, not fatal.
    private func persist(_ list: [HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(list)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Flowy: history persist failed: \(error)")
        }
    }

    /// Push a new snapshot to `@Published` on the main thread.
    private func publish(_ list: [HistoryEntry]) {
        if Thread.isMainThread {
            entries = list
        } else {
            DispatchQueue.main.async { self.entries = list }
        }
    }
}
