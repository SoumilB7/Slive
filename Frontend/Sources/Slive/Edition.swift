import Foundation

/// Which build this is (`SliveEdition` in Info.plist, set by build.sh).
/// Lite is the Swift app with on-device speech (WhisperKit, Parakeet) and no
/// Python server, so everything that needs the server is hidden: the
/// assistant, AI providers and local models, correct-answer labeling and
/// training. Full (and every dev build) has it all.
enum Edition {
    nonisolated static let hasServer: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "SliveEdition") as? String) != "lite"

    /// The server runs from Python bundled in the app (release Full build),
    /// not the repo's Backend/.venv (dev builds).
    nonisolated static let bundledServer: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "SliveBundledBackend") as? String) == "1"
}
