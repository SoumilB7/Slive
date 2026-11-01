import Foundation

/// The set-aside copies of a file Slive couldn't read: `<name>.corrupt-<epoch>`
/// next to the original. A store moves or copies the unreadable bytes here
/// before it writes fresh ones, so the only copy of the user's data is never
/// overwritten. The names are pinned by the self-test — existing backups on
/// users' disks must keep matching.
enum CorruptBackup {
    /// `history.json` → `history.json.corrupt-`.
    static func prefix(for file: URL) -> String {
        "\(file.lastPathComponent).corrupt-"
    }

    /// Where `file`'s unreadable bytes go when set aside at `date`.
    static func url(for file: URL, at date: Date) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(
            "\(prefix(for: file))\(Int(date.timeIntervalSince1970))")
    }

    /// The date a backup was set aside, read from its name; nil when `name`
    /// isn't a backup of `file`.
    static func date(name: String, for file: URL) -> Date? {
        let prefix = prefix(for: file)
        guard name.hasPrefix(prefix),
              let seconds = Int(name.dropFirst(prefix.count)) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Delete `file`'s backups set aside before `cutoff` (dated by name;
    /// `.distantFuture` = all of them).
    static func remove(of file: URL, olderThan cutoff: Date) {
        let dir = file.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            guard let date = date(name: name, for: file), date < cutoff else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Delete every file in `file`'s directory that carries its backup prefix.
    static func removeAll(of file: URL) {
        let dir = file.deletingLastPathComponent()
        let prefix = prefix(for: file)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    /// True when a backup of `file` already holds exactly its current size —
    /// the same bytes, set aside on an earlier launch with no rewrite since.
    static func hasCopyOfCurrentSize(_ file: URL) -> Bool {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let prefix = prefix(for: file)
        let copies = (try? FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return copies.contains(where: { $0.lastPathComponent.hasPrefix(prefix)
            && (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == size })
    }
}
