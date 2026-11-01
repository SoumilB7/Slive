import Foundation

/// One Codable value persisted as a single JSON file (ISO-8601 dates).
/// Saves are atomic; a file that won't decode is moved aside as a
/// `CorruptBackup` (never overwritten) and the caller starts fresh.
///
/// Not thread-safe by itself — the owning store serialises access (the
/// encoder and decoder are per instance, never shared across stores).
struct JSONFileStore<Value: Codable> {
    enum LoadResult {
        /// No file, or it couldn't be read: an empty start.
        case missing
        case ok(Value)
        /// It didn't decode. The bytes were moved here (nil if the move failed).
        case corrupt(movedTo: URL?)
    }

    let url: URL
    /// Names the file in log lines ("history" → "Slive: history unreadable…").
    let label: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(url: URL, label: String) {
        self.url = url
        self.label = label
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(now: Date = Date()) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        if let value = try? decoder.decode(Value.self, from: data) { return .ok(value) }
        // Start clean, never crash — but keep the bytes: the next save would
        // otherwise overwrite the only copy.
        let aside = CorruptBackup.url(for: url, at: now)
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            NSLog("Slive: \(label) unreadable — moved aside to \(aside.lastPathComponent)")
            return .corrupt(movedTo: aside)
        } catch {
            NSLog("Slive: \(label) unreadable and could not be moved aside: \(error)")
            return .corrupt(movedTo: nil)
        }
    }

    /// Atomic write: a crash mid-save leaves the previous file intact.
    func save(_ value: Value) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
