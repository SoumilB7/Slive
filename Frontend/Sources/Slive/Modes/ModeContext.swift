import AppKit
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
    /// Virtual time for the bounded model wait (`awaitServing`); the wall
    /// clock in the app, the Gauntlet's clock under simulation.
    let nowProvider: () -> Date
    /// How the model wait yields between polls — a real `Task.sleep` in the
    /// app, a virtual-time wake under simulation.
    let sleeper: Sleeper
    /// Why a dictate hold must be refused for secure input, or nil. The live
    /// system reading in the app; a fixed answer under test, which otherwise
    /// inherits this Mac's state (a locked screen refuses every hold).
    let secureInputNotice: () -> String?
    /// Wakes the front app's lazy accessibility tree at key-down (AXWake).
    /// A no-op under test: the real one writes to whatever app is in front
    /// of this Mac.
    let wakeFrontApp: @MainActor () -> Void

    init(recorder: Recording, speech: DictationSpeech, models: ModelServing,
         presenter: OverlayPresenter, queue: DictationQueue, session: SessionCoordinator,
         work: InFlightWork, settings: Settings, records: DictationRecords, report: FaultSink,
         typing: TextSink, typingBlockedNote: @escaping () -> String?,
         captureOptions: @escaping () -> CaptureOptions, cue: @escaping (HotkeyAction) -> Void,
         micAuthorization: @escaping () -> AVAuthorizationStatus,
         secureInputNotice: @escaping () -> String? = { TypingPolicy.secureInputHoldNotice() },
         wakeFrontApp: @escaping @MainActor () -> Void = {
             AXWake.wakeIfLazy(NSWorkspace.shared.frontmostApplication, minInterval: 2) },
         nowProvider: @escaping () -> Date = { Date() }, sleeper: Sleeper = TaskSleeper()) {
        self.recorder = recorder
        self.speech = speech
        self.models = models
        self.presenter = presenter
        self.queue = queue
        self.session = session
        self.work = work
        self.settings = settings
        self.records = records
        self.report = report
        self.typing = typing
        self.typingBlockedNote = typingBlockedNote
        self.captureOptions = captureOptions
        self.cue = cue
        self.micAuthorization = micAuthorization
        self.nowProvider = nowProvider
        self.sleeper = sleeper
        self.secureInputNotice = secureInputNotice
        self.wakeFrontApp = wakeFrontApp
        session.onSessionEnded = { [weak presenter] in presenter?.sessionEnded() }
    }

    static let micFailedMessage = "Couldn't start the microphone."
    static let micLostNote = "Mic disconnected · may be cut short"

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

    // Live streaming (ContinuousDictation). `onMicLost`: the mic dropped mid-stream.
    func startLiveDictation(model: String,
                            onUpdate: @escaping @MainActor (_ transcript: String, _ energy: Float) -> Void,
                            onFailure: (@MainActor () -> Void)?,
                            onMicLost: (@MainActor () -> Void)?) -> Bool
    func liveSamplesSnapshot(model: String) -> [Float]
    var liveConfirmedText: String { get }
    var liveConfirmedEndSeconds: Double { get }
    func stopLiveDictation()
}

extension TranscriptionModel: DictationSpeech {}

extension DictationSpeech {
    /// A dictation is waiting for `model`, but a stand-in may get there
    /// first: decode on whichever is resident first — `model`, or the one
    /// `standIn()` names (read each look, since residency promotes it
    /// mid-wait). `model`'s load keeps running either way. Without this a
    /// dictation released before the launch stand-in was ready waited out
    /// the whole Whisper compile (80s), and every later dictation — decoded
    /// in 0.1s on the stand-in — queued behind it.
    func awaitServing(_ model: String, standIn: @escaping @MainActor () -> String?,
                      poll: UInt64 = 200_000_000,
                      maxWait: TimeInterval = ModelWait.maxSeconds,
                      sleeper: Sleeper = TaskSleeper(),
                      now: @escaping () -> Date = { Date() }) async -> String {
        let load = ModelWait()
        Task { @MainActor in _ = await self.awaitReady(model); load.ended = true }
        let deadline = now().addingTimeInterval(maxWait)
        while !Task.isCancelled {
            if isReady(model) { return model }
            if let other = standIn(), other != model, isReady(other) { return other }
            // `model` won't arrive (load failed, not downloaded): stop
            // waiting; the decode path says why.
            if !canBecomeReady(model) { return model }
            // Its load ended without it resident (residency evicted it for a
            // newer pick): `canBecomeReady` stays true, and this polled until
            // that pick downloaded, or forever. The file path loads it again.
            if load.ended { return model }
            if now() > deadline {
                Log.event(String(format: "gave up waiting for %@ after %.0fs", model, maxWait))
                return model
            }
            await sleeper.sleep(nanoseconds: poll)
        }
        return model
    }
}

/// How `awaitServing` yields between model-readiness polls. The app sleeps
/// on the cooperative pool; the Gauntlet wakes it on virtual time so the
/// bounded-wait guarantee is checkable without real waits.
/// Main-actor isolated like its only caller: a nonisolated requirement made
/// every call hop through the cooperative pool before the sleep began, so
/// under load a simulated wait started an unpredictable number of main-queue
/// passes late.
protocol Sleeper: Sendable {
    @MainActor func sleep(nanoseconds: UInt64) async
}

/// Production sleeper: the same `Task.sleep` the poll loop always used.
struct TaskSleeper: Sleeper {
    @MainActor func sleep(nanoseconds: UInt64) async { try? await Task.sleep(nanoseconds: nanoseconds) }
}

/// `awaitServing`'s view of its load: whether it has ended, and the cap.
@MainActor final class ModelWait {
    /// No dictation waits longer than this; later ones queue behind it.
    nonisolated static let maxSeconds: TimeInterval = 300
    var ended = false
}

/// The mic capture a hold records with (`AudioRecorder`).
protocol Recording: AnyObject {
    var isRecording: Bool { get }
    @discardableResult func start(_ options: CaptureOptions) -> Bool
    @discardableResult func stop() -> RecordedAudio
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
    /// Test seams (the Gauntlet): a private training store and label run
    /// instead of the app's. nil in the app.
    var training: TrainingStore?
    var labels: LabelRun?

    func addToHistory(_ text: String) { HistoryStore.shared.add(text) }

    /// Training pair (audio + transcript) — only while saving is toggled on
    /// and under the size cap. Records regardless of where the text landed.
    /// Once saved, it's queued for its automatic label (Slive Custom 4).
    func addTrainingPair(_ text: String, audioURL: URL) {
        guard Self.savesTraining(capabilities: capabilities, captureEdits: settings.captureEdits,
                                 overLimit: (training ?? TrainingStore.shared).isOverLimit) else { return }
        if let id = (training ?? TrainingStore.shared).addRecording(transcript: text, audioURL: audioURL) {
            (labels ?? LabelRun.shared).labelNew(id: id)
        }
    }

    func recordPace(_ text: String, seconds: TimeInterval) {
        SpeakingStats.shared.record(text: text, seconds: seconds)
    }

    /// The training-pair gate: this build trains, saving is on, and there's
    /// room (the size check runs last, only when the rest allow it).
    static func savesTraining(capabilities: Capabilities, captureEdits: Bool,
                              overLimit: @autoclosure () -> Bool) -> Bool {
        capabilities.training && captureEdits && !overLimit()
    }
}
