import AVFoundation
import Foundation

/// What every dictation mode works with, built once by `AppContainer`.
/// Modes take their collaborators from here, never from `.shared`, so the
/// self-tests run them on fakes.
@MainActor struct ModeContext {
    let recorder: Recording
    let speech: DictationSpeech
    let models: ModelServing
    let presenter: OverlayPresenter
    /// Released dictations, typed in the order they were spoken (see DictationQueue).
    let queue: DictationQueue
    let session: SessionCoordinator
    let work: InFlightWork
    let settings: Settings
    let records: DictationRecords
    /// Real faults (`FailureReporter` in the app).
    let report: FaultSink
    /// Types at the caret (`TypingSink`).
    let typing: TextSink
    /// The copy box's line when typing was refused for something the user
    /// can fix (Accessibility off, secure input); nil otherwise.
    let typingBlockedNote: () -> String?
    /// How a hold records (`CaptureOptions.fromSettings()` in the app).
    let captureOptions: () -> CaptureOptions
    /// The activation sound for an action (`FeedbackPlayer`).
    let cue: (HotkeyAction) -> Void
    let micAuthorization: () -> AVAuthorizationStatus

    static let micFailedMessage = "Couldn't start the microphone."

    /// Where a finished dictation goes: typed at the caret, or — auto-insert
    /// off — the copy box.
    var sink: TextSink { settings.autoInsert ? typing : ClipboardSink() }

    /// The copy box's note for an untyped dictation: why typing was refused,
    /// but not when the user turned typing off themselves.
    var blockedNote: String? { settings.autoInsert ? typingBlockedNote() : nil }

    /// Mic permission, checked before every session: denied or never asked,
    /// macOS records pure zeros and the hold just faded away. False (after
    /// saying what to do) when nothing could be heard.
    func micAllowed() -> Bool {
        switch micAuthorization() {
        case .authorized:
            return true
        case .notDetermined:
            // The system prompt takes this hold either way; ask now.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            presenter.notice("Allow the microphone, then try again.")
        default:
            presenter.notice("Microphone blocked. Open Settings.")
        }
        Log.event("mic not authorized — hold aborted")
        return false
    }

    /// The overlay is this queued dictation's to update: it's the newest one
    /// waiting and no newer hold is live.
    func ownsOverlay(_ id: UUID) -> Bool {
        queue.isLast(id) && !session.isSessionLive
    }
}

/// Work that outlives one mode call and that any mode may cut short: the
/// supersedable in-flight request and the latency assertion held for
/// hold→type.
@MainActor final class InFlightWork {
    /// The in-flight assistant request (dictations queue instead). A new
    /// session, ✕ or quit cancels it.
    var request: Task<Void, Never>?
    /// Latency-critical activity assertion held for hold→type, so P-cores stay
    /// clocked and App Nap/timer coalescing can't stretch the pipeline.
    private var dictationActivity: NSObjectProtocol?
    private let queue: DictationQueue
    private let session: SessionCoordinator

    init(queue: DictationQueue, session: SessionCoordinator) {
        self.queue = queue
        self.session = session
    }

    func cancelRequest() {
        request?.cancel()
        request = nil
    }

    var holdsDictationActivity: Bool { dictationActivity != nil }

    func beginDictationActivity() {
        dictationActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Slive dictation")
    }

    private func endDictationActivity() {
        if let activity = dictationActivity {
            ProcessInfo.processInfo.endActivity(activity)
            dictationActivity = nil
        }
    }

    /// End the assertion once nothing still needs it: no hold live (a newer
    /// one is running on it) and no dictation decoding or waiting its turn.
    /// Every release's task ends through here — the cancelled / empty /
    /// no-audio exits used to leave it held.
    func endDictationActivityIfIdle() {
        guard queue.isEmpty, !session.isSessionLive else { return }
        endDictationActivity()
    }
}

// MARK: - Seams

/// What the modes ask of on-device speech: the `TranscriptionModel` facade
/// in the app, a fake in the self-tests.
@MainActor protocol DictationSpeech: AnyObject {
    func isReady(_ model: String) -> Bool
    func canBecomeReady(_ model: String) -> Bool
    func status(for model: String) -> ModelStatus
    func servingModel(wanted: String, fallback: String?) -> String
    func select(_ model: String)
    func primeIfCold(_ model: String)
    func awaitReady(_ model: String) async -> Bool
    func transcribeSamples(_ samples: [Float], model: String) async -> String?
    func transcribe(_ url: URL, model: String) async -> String?

    // Live streaming (ContinuousDictation)
    func startLiveDictation(model: String,
                            onUpdate: @escaping @MainActor (_ transcript: String, _ energy: Float) -> Void,
                            onFailure: (@MainActor () -> Void)?) -> Bool
    func liveSamplesSnapshot(model: String) -> [Float]
    var liveConfirmedText: String { get }
    var liveConfirmedEndSeconds: Double { get }
    func stopLiveDictation()
}

extension TranscriptionModel: DictationSpeech {}

/// The mic capture a hold records with (`AudioRecorder`).
protocol Recording: AnyObject {
    var isRecording: Bool { get }
    @discardableResult func start(_ options: CaptureOptions) -> Bool
    @discardableResult func stop() -> (url: URL?, samples: [Float])
}

extension AudioRecorder: Recording {}

/// Which models serve while a new pick prepares (`ModelResidency`).
@MainActor protocol ModelServing: AnyObject {
    var servingDictationModel: String? { get }
    var servingContinuousModel: String? { get }
    @discardableResult func downloadContinuousModelIfNeeded(retryFailed: Bool) -> Bool
}

extension ModelResidency: ModelServing {}

/// Where a delivered text is recorded — strictly after it was typed.
@MainActor protocol DictationRecords {
    /// The history catalogue (always).
    func addToHistory(_ text: String)
    /// A training pair (audio + transcript), if saving is on and has room.
    func addTrainingPair(_ text: String, audioURL: URL)
    /// Speaking stats.
    func recordPace(_ text: String, seconds: TimeInterval)
}

/// The app's records: HistoryStore, TrainingStore, SpeakingStats.
struct AppRecords: DictationRecords {
    let settings: Settings
    let capabilities: Capabilities

    func addToHistory(_ text: String) { HistoryStore.shared.add(text) }

    /// Training pair (audio + transcript) — only while saving is toggled on
    /// and under the size cap. Records regardless of where the text landed.
    func addTrainingPair(_ text: String, audioURL: URL) {
        guard capabilities.training, settings.captureEdits, !TrainingStore.shared.isOverLimit else { return }
        TrainingStore.shared.addRecording(transcript: text, audioURL: audioURL)
    }

    func recordPace(_ text: String, seconds: TimeInterval) {
        SpeakingStats.shared.record(text: text, seconds: seconds)
    }
}
