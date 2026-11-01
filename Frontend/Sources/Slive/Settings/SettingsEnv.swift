import Foundation

/// Everything the settings window's pages read, built once by
/// SettingsWindowController. Pages take what they need from it through their
/// init instead of reaching for `.shared` inside views, so a page's
/// dependencies are visible where it is built.
@MainActor
struct SettingsEnv {
    let settings: Settings
    let permissions: PermissionsModel
    let transcription: TranscriptionModel
    let providers: ProviderStore
    let trainingStore: TrainingStore
    /// Ground-truth runs outlive the Data page; pages only observe them.
    let labelRun: LabelRun
    let history: HistoryStore
    let stats: SpeakingStats
    let inputDevices: InputDevices
    let backend: BackendManager
    let promptLog: AssistantPromptLog
    let player: AudioPreviewPlayer
    let trainingClient: TrainingJobClient
    let promptClient: GroundTruthPromptClient
    /// Which pages this build shows (Lite has no server pages).
    let capabilities: Capabilities
    let relaunch: () -> Void
}
