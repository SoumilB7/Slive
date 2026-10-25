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
/// `~/Library/Application Support/Slive/history.json`. A missing file is an
/// empty catalogue; an unreadable one is moved aside (never overwritten) and
/// the catalogue starts fresh rather than crashing.
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

    /// Main-thread mirror for SwiftUI. Never the basis of a mutation: it
    /// trails `store` by a main-queue hop, so building the next list from it
    /// let two back-to-back dictations race and drop the first one.
    @Published private(set) var entries: [HistoryEntry] = []

    /// The source of truth. Read and written ONLY on `queue` (and once in
    /// init, before the queue has any work).
    private var store: [HistoryEntry] = []

    /// Serialises all mutation + persistence off the main thread; `@Published`
    /// writes are always hopped back to main.
    private let queue = DispatchQueue(label: "com.slive.history")
    private var pruneTimer: DispatchSourceTimer?

    /// nil = in-memory only (the self-test): nothing touches disk.
    private let fileURL: URL?

    private convenience init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Slive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("history.json"))
    }

    init(fileURL: URL?) {
        self.fileURL = fileURL
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

        mutate { list in
            list.insert(entry, at: 0)
            Self.applyBounds(&list)
        }
    }

    /// Remove a single entry by id.
    func remove(_ id: UUID) {
        mutate { list in list.removeAll { $0.id == id } }
    }

    /// Drop everything.
    func clearAll() {
        mutate { list in list.removeAll() }
    }

    /// The catalogue after every mutation queued so far has applied — unlike
    /// `entries`, which may still be waiting on its main-thread hop.
    func syncedEntries() -> [HistoryEntry] {
        queue.sync { store }
    }

    /// Apply `change` to the source of truth, then persist + mirror it.
    private func mutate(_ change: @escaping (inout [HistoryEntry]) -> Void) {
        queue.async {
            var next = self.store
            change(&next)
            self.store = next
            self.persist(next)
            self.publish(next)
        }
    }

    // MARK: Pruning + bounds

    /// Apply TTL then count cap. Order matters: expire first so the freshest
    /// 200 survive the count cap. Expects newest-first order.
    static func applyBounds(_ list: inout [HistoryEntry], now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-ttl)
        list.removeAll { $0.createdAt < cutoff }
        if list.count > maxEntries {
            list.removeLast(list.count - maxEntries)
        }
    }

    private func startPruneTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pruneInterval,
                       repeating: Self.pruneInterval,
                       leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var next = self.store
            let before = next.count
            Self.applyBounds(&next)
            guard next.count != before else { return }   // nothing expired
            self.store = next
            self.persist(next)
            self.publish(next)
        }
        timer.resume()
        pruneTimer = timer
    }

    // MARK: Persistence

    /// Where an unreadable history file is moved before starting fresh.
    static func corruptBackupURL(for url: URL, at date: Date) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(Int(date.timeIntervalSince1970))")
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode([HistoryEntry].self, from: data) else {
            // Start clean, never crash — but keep the bytes: the next add()
            // would otherwise overwrite the only copy of the user's history.
            let aside = Self.corruptBackupURL(for: fileURL, at: Date())
            do {
                try FileManager.default.moveItem(at: fileURL, to: aside)
                NSLog("Slive: history unreadable — moved aside to \(aside.lastPathComponent)")
            } catch {
                NSLog("Slive: history unreadable and could not be moved aside: \(error)")
            }
            return
        }
        decoded.sort { $0.createdAt > $1.createdAt }   // newest first
        let rawCount = decoded.count
        Self.applyBounds(&decoded)
        store = decoded
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
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(list)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Slive: history persist failed: \(error)")
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
