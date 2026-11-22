import Foundation

/// One Codable value persisted as a single JSON file (ISO-8601 dates).
/// Saves are atomic; a file that won't decode is moved aside as a
/// `CorruptBackup` (never overwritten) and the caller starts fresh. Lists load
/// with `loadElements`, which keeps every entry that still decodes.
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
        return setAside(now: now)
    }

    /// Start clean, never crash — but keep the bytes: the next save would
    /// otherwise overwrite the only copy.
    private func setAside(now: Date) -> LoadResult {
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

    /// Elements the array could not decode are dropped on their own, so one bad
    /// entry never costs the good ones. The original file is copied aside only
    /// when something was dropped, and the cleaned list replaces it only once
    /// that copy exists. A file that isn't a JSON array at all is set aside
    /// whole, like `load`.
    func loadElements<Element: Codable>(now: Date = Date()) -> LoadResult where Value == [Element] {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard let each = try? decoder.decode([Lossy<Element>].self, from: data) else {
            return setAside(now: now)
        }
        let kept = each.compactMap(\.element)
        guard kept.count < each.count else { return .ok(kept) }
        let copy = CorruptBackup.url(for: url, at: now)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            NSLog("Slive: \(label) had \(each.count - kept.count) unreadable entries — original kept as \(copy.lastPathComponent)")
            try save(kept)
        } catch {
            NSLog("Slive: \(label) had unreadable entries and could not be rewritten: \(error)")
        }
        return .ok(kept)
    }

    /// One array slot that never throws, so a bad element can't fail the array.
    private struct Lossy<Element: Decodable>: Decodable {
        let element: Element?
        init(from decoder: Decoder) { element = try? Element(from: decoder) }
    }

    /// Atomic write: a crash mid-save leaves the previous file intact.
    func save(_ value: Value) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
