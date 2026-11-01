import Foundation

/// How one engine turns a model's files into a resident `Recognizer`.
@MainActor
protocol ModelLoader {
    /// `id`'s load, or nil when its files aren't there (→ Not downloaded).
    func plan(_ id: String) -> LoadPlan?
}

/// One model's load as its engine runs it. `ModelLoads` adds what every
/// engine shares: the status, the 600 s timeout, the cooldown after a
/// failure, serving the interim copy, and the warm-up.
struct LoadPlan {
    /// Status until the engine reports its own stages.
    var firstStage: String
    /// Logged with the load's start.
    var detail: String
    /// The real (Neural Engine) load; `stage` posts the engine's load stages.
    var load: @MainActor (_ stage: @escaping @MainActor (String) -> Void) async throws -> any Recognizer
    /// A copy that needs no compile, served while `load` is still running
    /// after `after` seconds; the real copy replaces it.
    var interim: Interim?
    var copy: LoadFailureCopy

    struct Interim {
        var after: Double
        var load: @MainActor () async -> (any Recognizer)?
    }
}

/// What a person reads when a load fails.
struct LoadFailureCopy {
    var engine: String
    var timedOutStatus: String
    var timedOutReport: String
    var failedReport: String
}
