import AVFoundation
import Foundation

/// The composition root: builds the long-lived objects once (when the app
/// delegate is created, as they always were) and owns them. Everything is
/// handed its collaborators here; AppDelegate keeps the lifecycle, the
/// modes (`ModeRegistry`) do what a gesture asks.
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
    let continuous: ContinuousDictation
    /// Every released dictation (and an assistant request released while the
    /// model loads): never cancelled by a newer hold, typed in the order they
    /// were spoken.
    let dictations = DictationQueue()

    let presenter: OverlayPresenter
    let residency: ModelResidency
    let session: SessionCoordinator
    let menuBar: MenuBarController
    /// The in-flight assistant request and the latency assertion.
    let work: InFlightWork
    /// Dictate / Assist / Stream, as this build offers them.
    let modes: ModeRegistry

    init() {
        let model = overlayModel
        // The panel is built on first use (the first hold), not here.
        presenter = OverlayPresenter(model: model) { OverlayController(model: model) }
        residency = ModelResidency(whisper: whisper)
        session = SessionCoordinator(holdDelay: { Settings.shared.holdActivationDelay })
        menuBar = MenuBarController(backend: backend, settingsWindow: settingsWindow)
        work = InFlightWork(queue: dictations, session: session)
        continuous = ContinuousDictation(speech: whisper)

        let settings = Settings.shared
        let capabilities = Capabilities.current
        let context = ModeContext(
            recorder: recorder, speech: whisper, models: residency, presenter: presenter,
            queue: dictations, session: session, work: work, settings: settings,
            records: AppRecords(settings: settings, capabilities: capabilities),
            report: .app, typing: TypingSink(),
            typingBlockedNote: { TypingPolicy.typingBlockedNote },
            captureOptions: { .fromSettings() },
            cue: { FeedbackPlayer.shared.playActivation(for: $0) },
            micAuthorization: { AVCaptureDevice.authorizationStatus(for: .audio) })
        // Lite registers no assistant mode, so nothing there uses this.
        let server = ServerAssistant(backend: backend, client: assistant, settings: settings)
        modes = .standard(context, continuous: continuous, assistant: server,
                          capabilities: capabilities)
    }
}
