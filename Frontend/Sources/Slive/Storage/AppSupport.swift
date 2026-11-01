import Foundation

/// Where Slive keeps its files: `~/Library/Application Support/Slive`.
/// One place for the folder names, so a store can't drift to a sibling path.
/// Callers create the directories they write into.
enum AppSupport {
    /// `~/Library/Application Support/Slive` (the temp dir if Application
    /// Support can't be resolved — never seen, but never a crash either).
    static var root: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Slive", isDirectory: true)
    }

    /// The 24 h transcript catalogue (`HistoryStore`).
    static var historyFile: URL { root.appendingPathComponent("history.json") }

    /// Captured training samples: `samples.jsonl` + `audio/` (`TrainingStore`).
    static var trainingDirectory: URL { root.appendingPathComponent("training", isDirectory: true) }
}
