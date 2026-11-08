import Foundation

/// Where Slive keeps its files: `~/Library/Application Support/Slive`.
/// One place for the folder names, so a store can't drift to a sibling path.
/// Callers create the directories they write into.
enum AppSupport {
    /// `~/Library/Application Support/Slive` (the temp dir if Application
    /// Support can't be resolved — never seen, but never a crash either).
    static var root: URL {
        // The Settings render self-test points its child processes at a temp
        // folder, so "the test wrote nothing" is checked on a folder nothing
        // else writes to (the running app saves history here).
        if let test = ProcessInfo.processInfo.environment[testRootVariable], !test.isEmpty {
            return URL(fileURLWithPath: test, isDirectory: true)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Slive", isDirectory: true)
    }

    static let testRootVariable = "SLIVE_TEST_APP_SUPPORT"

    /// The 24 h transcript catalogue (`HistoryStore`).
    static var historyFile: URL { root.appendingPathComponent("history.json") }

    /// Captured training samples: `samples.jsonl` + `audio/` (`TrainingStore`).
    static var trainingDirectory: URL { root.appendingPathComponent("training", isDirectory: true) }
}
