import Foundation

/// Which build this is (`SliveEdition` in Info.plist, set by build.sh).
/// Lite is the Swift app with on-device speech (WhisperKit, Parakeet) and no
/// Python server, so everything that needs the server is hidden: the
/// assistant, AI providers and local models, correct-answer labeling and
/// training. Full (and every dev build) has it all.
enum Edition {
    nonisolated static let hasServer: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "SliveEdition") as? String) != "lite"
}

/// What this build offers, decided once from the edition. Features ask for
/// the capability they need rather than the edition, so one can later move
/// (say, a cloud assistant in Lite) without hunting down every check.
struct Capabilities: Equatable {
    /// A local server ships with the app (its status line, its lifecycle).
    var server: Bool
    /// The assistant shortcut: speech → LLM answer.
    var assistant: Bool
    /// AI provider keys and model lists.
    var providers: Bool
    /// Local (MLX) models served by the server.
    var localModels: Bool
    /// Training-data capture, correct-answer labeling, fine-tuning.
    var training: Bool

    /// Today every capability rides on the server.
    init(hasServer: Bool) {
        server = hasServer
        assistant = hasServer
        providers = hasServer
        localModels = hasServer
        training = hasServer
    }

    nonisolated static let current = Capabilities(hasServer: Edition.hasServer)
}
