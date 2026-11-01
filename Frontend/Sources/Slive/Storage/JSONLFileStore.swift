import Foundation

/// An append-only JSON Lines file (one Codable element per line, ISO-8601
/// dates). Appends never rewrite what's there; a line that won't decode costs
/// only itself, and is copied aside once before a rewrite could drop it.
///
/// Not thread-safe by itself — the owning store serialises access.
struct JSONLFileStore<Element: Codable> {
    let url: URL
    /// Names the file in log lines ("training index").
    let label: String
    private let encoder: JSONEncoder

    init(url: URL, label: String) {
        self.url = url
        self.label = label
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    /// Append one element as a line, returning the bytes written. Throws when
    /// it can't be encoded or written — the file is then untouched.
    @discardableResult
    func append(_ element: Element) throws -> Int64 {
        var line = try encoder.encode(element)
        line.append(0x0A)   // newline-delimited JSON
        return try appendLine(line)
    }

    /// A torn last line (crash mid-append) gets a newline first, so only it
    /// stays broken — gluing onto it would make the new element undecodable too.
    private func appendLine(_ line: Data) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Never overwrite here: a file that exists but failed to open
            // must not be replaced by this one line.
            try line.write(to: url, options: .withoutOverwriting)
            return Int64(line.count)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var out = line
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if !Self.endsLine(try handle.read(upToCount: 1)) { out.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: out)
        return Int64(out.count)
    }

    /// True when the file's last byte closes a line (or there is none).
    static func endsLine(_ lastByte: Data?) -> Bool {
        guard let byte = lastByte?.first else { return true }
        return byte == 0x0A
    }

    /// Replace the whole file atomically with `elements` (one that won't
    /// encode is skipped). Returns the bytes written.
    @discardableResult
    func rewrite(_ elements: [Element]) throws -> Int64 {
        var blob = Data()
        for element in elements {
            guard let line = try? encoder.encode(element) else { continue }
            blob.append(line)
            blob.append(0x0A)
        }
        try blob.write(to: url, options: .atomic)
        return Int64(blob.count)
    }

    /// Read every decodable element. Unreadable lines are copied aside first
    /// (once per distinct file — see `CorruptBackup.hasCopyOfCurrentSize`),
    /// since the next rewrite writes only what decoded.
    func load(now: Date = Date()) -> [Element] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let parsed = Self.parse(data)
        if parsed.undecodable > 0 {
            // The next rewrite writes the decoded elements only — keep the
            // bytes we couldn't read before it drops them for good.
            let aside = CorruptBackup.url(for: url, at: now)
            // Already set aside, byte for byte (no rewrite since the last
            // launch): one copy is enough — don't add one per launch.
            if CorruptBackup.hasCopyOfCurrentSize(url) { return parsed.elements }
            do {
                try FileManager.default.copyItem(at: url, to: aside)
                NSLog("Slive: \(parsed.undecodable) unreadable \(label) line(s) — copied to \(aside.lastPathComponent)")
            } catch {
                NSLog("Slive: \(label) has unreadable lines and could not be copied aside: \(error)")
            }
        }
        return parsed.elements
    }

    /// Decode JSONL byte-wise (a bad byte costs one line, not the whole
    /// file), counting the non-blank lines that didn't decode.
    static func parse(_ data: Data) -> (elements: [Element], undecodable: Int) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var elements: [Element] = []
        var bad = 0
        for line in data.split(separator: 0x0A) {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            if let element = try? decoder.decode(Element.self, from: Data(line)) {
                elements.append(element)
            } else {
                bad += 1
            }
        }
        return (elements, bad)
    }

    /// Delete the file and every backup of it.
    func removeAll() {
        try? FileManager.default.removeItem(at: url)
        CorruptBackup.removeAll(of: url)
    }
}
