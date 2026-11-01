import Foundation

/// The composition root: builds the long-lived objects once (when the app
/// delegate is created, as they always were) and owns them. Everything is
/// handed its collaborators here; AppDelegate keeps the lifecycle and the
/// flows.
@MainActor final class AppContainer {
    /// What the overlay shows (the SwiftUI views read it).
    let overlayModel = AudioModel()
    let recorder = AudioRecorder()
    let hotkey = HotkeyMonitor()
    let settingsWindow = SettingsWindowController()
    let whisper = TranscriptionModel.shared   // on-device STT (Neural Engine)
    let assistant = AssistantClient()
    let backend = BackendManager.shared
    /// Continuous (live streaming) dictation — a fully separate flow from the
    /// main press-and-release dictation so the two never interfere.
    let continuous = ContinuousDictation()
    /// Every released dictation (and an assistant request released while the
    /// model loads): never cancelled by a newer hold, typed in the order they
    /// were spoken.
    let dictations = DictationQueue()

    let presenter: OverlayPresenter
    let residency: ModelResidency
    let session: SessionCoordinator
    let menuBar: MenuBarController

    init() {
        let model = overlayModel
        // The panel is built on first use (the first hold), not here.
        presenter = OverlayPresenter(model: model) { OverlayController(model: model) }
        residency = ModelResidency(whisper: whisper)
        session = SessionCoordinator(holdDelay: { Settings.shared.holdActivationDelay })
        menuBar = MenuBarController(backend: backend, settingsWindow: settingsWindow)
    }
}
