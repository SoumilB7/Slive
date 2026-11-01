import Foundation
import SliveReport

/// What the reporter has already offered, so nobody is asked twice about the
/// same thing: crash files by name, other problems by signature for a day.
/// ~/Library/Application Support/Slive/Reporter/state.json
struct ReporterState: Codable {
    var offered: [String: Date] = [:]
    var seenCrashFiles: [String] = []

    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Slive/Reporter/state.json")
    }()

    static let quietPeriod: TimeInterval = 24 * 3600

    static func load() -> ReporterState {
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(ReporterState.self, from: data) {
            return state
        }
        // First run: crashes from before the reporter existed aren't news.
        var fresh = ReporterState()
        fresh.seenCrashFiles = CrashReport.list().map { $0.url.lastPathComponent }
        fresh.save()
        return fresh
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    func recentlyOffered(_ signature: String) -> Bool {
        guard let at = offered[signature] else { return false }
        return Date().timeIntervalSince(at) < Self.quietPeriod
    }

    mutating func markOffered(_ signature: String) {
        offered[signature] = Date()
        offered = offered.filter { Date().timeIntervalSince($0.value) < Self.quietPeriod * 7 }
        save()
    }

    mutating func markSeen(_ crashFile: String) {
        guard !seenCrashFiles.contains(crashFile) else { return }
        seenCrashFiles.append(crashFile)
        seenCrashFiles = Array(seenCrashFiles.suffix(200))
        save()
    }
}
