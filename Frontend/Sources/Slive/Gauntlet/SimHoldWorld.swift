import AVFoundation
import Combine
import Foundation
import SliveTestKit

/// The hold-path world one seed explores: the real modes on fakes, a shared
/// virtual clock, and a seeded chaos world that resolves every async
/// completion at a random virtual delay. See `SimHold` for the family.
@MainActor
final class SimHoldWorld {
    /// What `run` reports back for the ledger and shrinking.
    struct RunResult {
        let failingIDs: Set<String>
        let noise: Int
        let utterances: Int
    }

    // Shared virtual time for the gesture machine, the overlay and every
    // simulated async completion, so one clock orders the whole world.
    let clock = ManualScheduler()
    private var world: SeededRandom      // async delays and faults
    private let settings: Settings
    private let pipeline = DictationPipeline.standard(vocabulary: "")

    private let recorder: SimHoldMic
    private let speech: SimSpeech
    private let models = SimModels()
    private let presenter: OverlayPresenter
    private let sink: SimSink
    private let assistant = SimAssistant()
    private let registry: ModeRegistry
    private let session: SessionCoordinator
    private let work: InFlightWork
    private let queue = DictationQueue()
    private var cancellable: AnyCancellable?
    private var createdFiles: [URL] = []

    // Oracle ledger.
    private var utterances: [Utterance] = []
    fileprivate var byToken: [String: Utterance] = [:]
    fileprivate var byFinished: [String: Utterance] = [:]
    fileprivate var deliveringUtterance: Utterance?
    private var violations: Set<String> = []
    /// Bumped by every seam call/resume, so the executor pump knows work is
    /// still flowing and never stops mid-chain.
    fileprivate var tick = 0

    private let micLostChance: Double
    private let failStartChance: Double
    private let scenario: ModelScenario

    init(seed: UInt64, settings: Settings) {
        self.settings = settings
        world = SeededRandom(seed: seed ^ 0x51D5_1AE9_2C3B_7F11)   // independent of script generation
        // Draw the fault profile first, so it's fixed for the whole replay.
        scenario = ModelScenario.allCases.randomElement(using: &world)!
        micLostChance = Double.random(in: 0...0.3, using: &world)
        failStartChance = Double.random(in: 0...0.08, using: &world)

        settings.whisperModel = "whisper"
        settings.continuousModel = "whisper"
        settings.autoInsert = true
        settings.hotwords = ""
        settings.holdActivationDelay = 0.15
        settings.captureEdits = true
        var assistantConfig = settings.assistantConfig
        assistantConfig.attachScreenshot = false
        settings.assistantConfig = assistantConfig

        let model = AudioModel()
        let surface = OverlayStateTests.FakeSurface(model: model)
        presenter = OverlayPresenter(model: model, scheduler: clock) { surface }
        session = SessionCoordinator(scheduler: clock, holdDelay: { settings.holdActivationDelay })
        work = InFlightWork(queue: queue, session: session)

        recorder = SimHoldMic()
        speech = SimSpeech()
        sink = SimSink()
        let sleeper = WorldSleeper()

        let records = SimRecords()
        let clockRef = clock   // captured by value: the closures mustn't touch self
        let ctx = ModeContext(
            recorder: recorder, speech: speech, models: models, presenter: presenter,
            queue: queue, session: session, work: work, settings: settings, records: records,
            report: FaultSink { _, _, _, _, _, _, _ in },
            typing: sink, typingBlockedNote: { nil },
            captureOptions: { CaptureOptions() }, cue: { _ in },
            micAuthorization: { .authorized },
            secureInputNotice: { nil }, wakeFrontApp: {},
            nowProvider: { MainActor.assumeIsolated { clockRef.now } },
            sleeper: sleeper)
        registry = ModeRegistry.standard(ctx, continuous: ContinuousDictation(speech: speech, sink: ClipboardSink(),
                                                                              settings: settings),
                                         assistant: assistant, capabilities: Capabilities(hasServer: true),
                                         screenshot: { nil })
        session.handler = registry

        // Wire the fakes back to the world now that it's fully built.
        recorder.world = self
        speech.world = self
        sink.world = self
        records.world = self
        sleeper.world = self
        assistant.world = self
        applyScenario()
        cancellable = model.$state.sink { [weak self] state in self?.onState(state) }
    }

    // MARK: - Driving

    func run(_ steps: [SimStep]) -> RunResult {
        for step in steps {
            advance(by: step.gap)
            apply(step.event)
            settle()
            checkStep()
        }
        // Let go of anything still live, as the user would, so quiescence
        // measures real hangs, not a script (often a shrunk one) that stopped
        // mid-gesture. Through `apply`, so the ledger sees these releases too.
        if keyHeld { apply(.release); settle() }
        if let live = session.toggleActive { apply(.toggle(live)); settle() }
        finalize()
        var failing = violations
        checkFinal(into: &failing)
        cleanUp()
        let dictations = utterances.filter { $0.action == .dictate }
        let noise = dictations.filter { $0.typedConfirmed && $0.boxShown }.count
        return RunResult(failingIDs: failing, noise: noise, utterances: dictations.count)
    }

    /// Advance virtual time by `seconds`, firing each due timer one at a time
    /// and settling the world between them so async continuations resolve
    /// in a controlled order.
    private func advance(by seconds: TimeInterval) {
        let target = clock.now.addingTimeInterval(seconds)
        while let due = clock.nextDue, due <= target {
            clock.advanceToNext()
            settle()
        }
        if clock.now < target { clock.advance(by: target.timeIntervalSince(clock.now)) }
    }

    /// Run everything that can happen at this virtual instant. Every async
    /// hop on the path lands on the main queue in FIFO order (main-actor
    /// fakes, a main-actor sleeper), so draining it pass by pass reaches the
    /// same point however busy the Mac is; virtual time never moves while
    /// work is still in flight. The one exception is the assistant's answer
    /// stream: its iteration and throttle sleep go through the cooperative
    /// pool on real time, so an open stream is waited for (it needs no
    /// virtual time to finish) before the world moves on.
    private func settle() {
        let realLimit = Date().addingTimeInterval(Self.realWorkLimit)
        var calm = 0
        while calm < Self.calmPasses {
            let before = tick
            Self.drainMainQueue()
            if streamOpen || inFlight > 0 {
                calm = 0
                if Date() > realLimit { stuckStream = true; return }
                usleep(20)
                continue
            }
            calm = tick == before ? calm + 1 : 0
        }
    }

    /// Main-queue passes with no visible move before the instant counts as
    /// settled. A pass runs every job queued before it, so this has to
    /// outlast the longest chain of jobs that touch nothing the world sees
    /// (a Task starting, a queue turn handed on) — and a continuation that
    /// detours through the cooperative pool can take up to ~48 passes to
    /// reach the main queue on a busy Mac (measured, 9dd195a). 8 passes
    /// lost a seed in ~1 of 6 loaded runs.
    private static let calmPasses = 64
    /// A safety net for real work only (the answer stream takes
    /// milliseconds); past it the stream is reported as hung.
    private static let realWorkLimit: TimeInterval = 10

    /// One pass over the main queue: every job queued so far, up to a marker.
    private static func drainMainQueue() {
        let target = markers + 1
        DispatchQueue.main.async { MainActor.assumeIsolated { markers += 1 } }
        while markers < target { _ = CFRunLoopRunInMode(.defaultMode, 0, true) }
    }
    private static var markers = 0

    /// Drain the remaining timers up to the virtual cap; the end is decided
    /// by the world (no timer left in reach, everything settled), never by
    /// wall time. Past the cap a still non-empty queue is a genuine hang
    /// (P-EVERY-WAIT-BOUNDED and the quiescence check catch it).
    private func finalize() {
        settle()
        while let due = clock.nextDue, due.timeIntervalSinceReferenceDate <= SimHold.virtualCap {
            clock.advanceToNext()
            settle()
        }
    }

    private func apply(_ event: SimEvent) {
        switch event {
        case .press(let a):
            keyHeld = true
            session.keyDown(a)
        case .release:
            keyHeld = false
            if recorder.isRecording { noteRelease(session.currentAction) }
            session.keyUp()
        case .toggle(let a):
            if session.toggleActive == a, recorder.isRecording { noteRelease(a) }
            session.toggleTapped(a)
        case .dismiss:
            // The ✕ wiring (AppDelegate.dismissOverlay).
            work.cancelRequest()
            session.endToggle()
            registry.dismissAll()
            presenter.dismiss()
        case .setModel(let m):
            settings.whisperModel = m
            speech.set(m, .ready, downloaded: true)   // a downloaded pick change
        case .flipAuto:
            settings.autoInsert.toggle()
        }
    }

    // MARK: - Oracle ledger

    /// Note a released hold as an utterance that must reach a terminal state
    /// (dictation) or at least settle (assistant). Called the moment the key
    /// lifts, before the decode, so a release that is later dropped is still
    /// on the books.
    private func noteRelease(_ action: HotkeyAction) {
        guard let token = recorder.currentToken else { return }
        noteRelease(action, token: token, lost: recorder.currentLost)
    }

    private func noteRelease(_ action: HotkeyAction, token: String, lost: Bool) {
        guard action == .dictate || action == .assist else { return }
        guard byToken[token] == nil else { return }
        let finished = pipeline.correct(pipeline.clean(token))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let u = Utterance(token: token, tokenNum: Int(token.dropFirst()) ?? 0, action: action,
                          finished: finished, autoInsert: settings.autoInsert,
                          micWasLost: lost,
                          recordStart: recorder.startTime[token] ?? clock.now,
                          releaseTime: clock.now)
        utterances.append(u)
        byToken[token] = u
        if action == .dictate { byFinished[finished] = u }
    }

    /// The mic stopped on a recording no scripted release noted: a press
    /// that ended a live toggle session, say. Still a release the user
    /// made, so it goes on the books (at the stop, its tail included).
    fileprivate func noteStop(token: String, lost: Bool) {
        noteRelease(session.currentAction, token: token, lost: lost)
    }

    fileprivate func noteDecode(token: String, model: String) {
        guard let u = byToken[token] else { return }
        u.decodedBy = model
        u.pickAtDecode = settings.whisperModel
    }

    private func onState(_ state: OverlayState) {
        tick += 1
        guard case .result(let r) = state else { return }
        if r.text == ModeContext.micLostNote || r.note == ModeContext.micLostNote {
            if let u = deliveringUtterance {
                u.sawMicNote = true   // shown as it typed: that dictation's
            } else {
                // Shown later, once a newer hold let go (alone or on the
                // waiting copy box): for the mic-lost dictations typed before it.
                for u in utterances where u.micWasLost && u.typingSinkDelivered { u.sawMicNote = true }
            }
        }
        if r.text == ModeContext.micLostNote { return }
        // Several unconfirmed dictations share one box, a blank line apart.
        for part in r.text.components(separatedBy: "\n\n") {
            guard let u = byFinished[part] else { continue }
            u.boxShown = true
            if r.note == ModeContext.micLostNote { u.sawMicNote = true }
            // One-owner: a dictation's box must never surface while a strictly
            // newer hold is still capturing (its pill owns the overlay).
            if recorder.isRecording, let cur = recorder.currentToken,
               (Int(cur.dropFirst()) ?? 0) > u.tokenNum {
                violations.insert("sim-hold.one-owner")
            }
        }
    }

    // MARK: - Checks

    /// After every step: pick up any violation flagged by the live observer
    /// (kept in `violations`); the heavy checks run at the end on the settled
    /// world. Present as a method so the per-step contract is explicit.
    private func checkStep() {}

    private func checkFinal(into failing: inout Set<String>) {
        let now = clock.now
        var expectedField = ""
        for u in utterances where u.action == .dictate {
            if u.landed { expectedField += u.finished }

            let terminal = u.typedConfirmed || u.boxShown
                || (u.sawMicNote && u.inHistory)
                // The copy-box sink (auto-insert off) on a non-owner dictation
                // keeps it in history by design — no box, no loss.
                || (!u.typingSinkDelivered && u.inHistory)
            // A short false start the user aborted with a double-tap is a
            // legitimate drop; a real (decoded, or ≥1 s) hold must not vanish.
            let mustNotLose = u.decodedBy != nil
                || u.releaseTime.timeIntervalSince(u.recordStart) >= SessionCoordinator.falseStartWindow
            if mustNotLose && !terminal { failing.insert("P-NO-LOSS") }

            if mustNotLose && !terminal && now.timeIntervalSince(u.releaseTime) > SimHold.waitBoundSeconds {
                failing.insert("P-EVERY-WAIT-BOUNDED")
            }
            if u.trainingPaired, u.decodedBy != u.pickAtDecode { failing.insert("F14") }
            // A mic lost mid-hold must be surfaced — never typed silently. It
            // only applies once delivery actually happened (typed or boxed);
            // a non-owner copy-box dictation is history-only by design.
            if u.micWasLost, u.decodedBy != nil, u.landed || u.boxShown, !u.sawMicNote {
                failing.insert("F8")
            }
        }
        if sink.field != expectedField { failing.insert("sim-hold.order") }
        if !quiescent { failing.insert("sim-hold.quiescent") }
    }

    /// The end state the quiescence promise wants: nothing capturing or
    /// queued, every release's task ended, the latency assertion dropped,
    /// the overlay resting.
    private var quiescent: Bool {
        guard queue.isEmpty, !registry.isCapturing, session.toggleActive == nil,
              !session.isSessionLive, !work.holdsDictationActivity, tasksEnded, !stuckStream else { return false }
        switch presenter.state {
        case .listening, .transcribing: return false
        case .idle: return true
        case .result(let r): return !r.isStreaming
        }
    }

    /// Every release's task has returned. Each one deletes its recording on
    /// its way out (HoldCapture's `defer`), so a recording still on disk is a
    /// task still running or parked; read straight from the world, with no
    /// watcher Task whose own wake-up would depend on load.
    private var tasksEnded: Bool {
        recorder.recordings.values.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The assistant answer streams whose release task hasn't returned yet.
    /// Its stream iteration and throttle sleep run on the cooperative pool in
    /// real time, so `settle` waits these out instead of moving virtual time.
    fileprivate var openStreams: [URL] = []
    private var streamOpen: Bool {
        openStreams.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        return !openStreams.isEmpty
    }
    /// An answer stream outlived `realWorkLimit`: a hang, never a slow Mac.
    private var stuckStream = false
    /// Tasks a world wake resumed that haven't run yet. Settling waits for
    /// them in real time: when a resumed task actually gets the main thread
    /// depends on load, what it then does never does.
    fileprivate var inFlight = 0
    /// The scripted hotkey is down (pressed, not yet released).
    private var keyHeld = false

    fileprivate func streamStarted(question: String) {
        bump()
        if let url = recorder.recordings[question] { openStreams.append(url) }
    }

    // MARK: - Scenario

    private func applyScenario() {
        switch scenario {
        case .ready:
            speech.set("whisper", .ready, downloaded: true)
        case .loadThenReady:
            speech.set("whisper", .preparing("Loading"), downloaded: true)
            speech.loadOutcome = .becomesReady
        case .standIn:
            speech.set("whisper", .preparing("Loading"), downloaded: true)
            speech.set("parakeet", .ready, downloaded: true)
            models.servingDictationModel = "parakeet"
        case .evicted:
            // The pick's load ends without it resident (residency evicted it
            // for a newer pick): still on disk, never ready — the F3 trap.
            speech.set("whisper", .preparing("Loading"), downloaded: true)
            speech.loadOutcome = .endsNotResident
        }
    }

    fileprivate func decodeDelay() -> TimeInterval { Double.random(in: 0.02...0.3, using: &world) }
    fileprivate func loadDelay() -> TimeInterval { Double.random(in: 0.1...2.0, using: &world) }
    fileprivate func chooseReceipt() -> DeliveryVerifier.Receipt {
        let r = Double.random(in: 0...1, using: &world)
        if r < 0.6 { return .landed }
        return r < 0.8 ? .notYet : .unknown
    }
    fileprivate func wantsMicLost() -> Bool { Double.random(in: 0...1, using: &world) < micLostChance }
    fileprivate func wantsFailStart() -> Bool { Double.random(in: 0...1, using: &world) < failStartChance }

    private func cleanUp() {
        cancellable?.cancel()
        queue.cancelAll()
        for url in createdFiles { try? FileManager.default.removeItem(at: url) }
    }

    fileprivate func registerFile(_ url: URL) { createdFiles.append(url) }
}

/// What the picked model's load does this seed.
private enum ModelScenario: CaseIterable { case ready, loadThenReady, standIn, evicted }

// MARK: - The intent ledger entry

/// One released hold, tracked from key-up to its terminal outcome.
@MainActor final class Utterance {
    let token: String
    let tokenNum: Int
    let action: HotkeyAction
    let finished: String
    let autoInsert: Bool
    let micWasLost: Bool
    let recordStart: Date
    let releaseTime: Date

    var decodedBy: String?
    var pickAtDecode: String?
    var landed = false            // keystrokes registered in the field
    var typedConfirmed = false    // and a receipt confirmed it
    var boxShown = false          // the copy box surfaced this text
    var sawMicNote = false        // a mic-lost notice/box-note was shown
    var inHistory = false
    var trainingPaired = false
    var typingSinkDelivered = false   // the typing sink (auto-insert on) took it, vs the copy-box sink

    init(token: String, tokenNum: Int, action: HotkeyAction, finished: String, autoInsert: Bool,
         micWasLost: Bool, recordStart: Date, releaseTime: Date) {
        self.token = token
        self.tokenNum = tokenNum
        self.action = action
        self.finished = finished
        self.autoInsert = autoInsert
        self.micWasLost = micWasLost
        self.recordStart = recordStart
        self.releaseTime = releaseTime
    }
}

// MARK: - Fakes at the ModeContext seams

/// The mic: a fresh token per recording, encoded in the first sample so the
/// speech fake decodes it back (fake audio → fake speech, one token).
/// Nonisolated like the production recorder (and the other test recorders);
/// `HoldCapture` only ever calls it on the main actor, so world access is
/// taken through `assumeIsolated`.
final class SimHoldMic: Recording, @unchecked Sendable {
    weak var world: SimHoldWorld?
    private(set) var isRecording = false
    private(set) var currentToken: String?
    private(set) var currentLost = false
    var startTime: [String: Date] = [:]
    /// Each token's recording, which its release task deletes when it ends.
    private(set) var recordings: [String: URL] = [:]
    private var counter = 0

    func start(_ options: CaptureOptions) -> Bool {
        MainActor.assumeIsolated {
            guard world?.wantsFailStart() != true else { return false }
            counter += 1
            let token = "w\(counter)"
            currentToken = token
            currentLost = world?.wantsMicLost() ?? false
            startTime[token] = world?.clockNow
            isRecording = true
            return true
        }
    }

    func stop() -> RecordedAudio {
        MainActor.assumeIsolated {
            isRecording = false
            guard let token = currentToken, let id = Int(token.dropFirst()) else {
                return RecordedAudio(url: nil, samples: [])
            }
            // All-loud sine so SilenceTrim keeps the whole buffer (the token in
            // sample 0 survives); `deviceLost` carries a mid-hold mic drop.
            var samples = (0..<16_000).map { Float(sin(Double($0) * 0.17) * 0.3) }
            samples[0] = Float(id)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("slive-simhold-\(UUID().uuidString).wav")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            world?.registerFile(url)
            recordings[token] = url
            let lost = currentLost
            world?.noteStop(token: token, lost: lost)
            currentToken = nil
            currentLost = false
            return RecordedAudio(url: url, samples: samples, deviceLost: lost)
        }
    }
}

private extension SimHoldWorld { var clockNow: Date { clock.now } }

/// On-device speech on fakes: a status table the world mutates, decodes that
/// return the token after a world-chosen delay, and loads that finish on
/// virtual time.
@MainActor final class SimSpeech: DictationSpeech {
    weak var world: SimHoldWorld?
    private var statuses: [String: ModelStatus] = [:]
    private var downloaded: Set<String> = []
    enum LoadOutcome { case becomesReady, endsNotResident, none }
    var loadOutcome: LoadOutcome = .none

    func set(_ model: String, _ s: ModelStatus, downloaded dl: Bool) {
        statuses[model] = s
        if dl { downloaded.insert(model) } else { downloaded.remove(model) }
    }

    func isReady(_ model: String) -> Bool { statuses[model] == .ready }
    func canBecomeReady(_ model: String) -> Bool {
        if isReady(model) { return true }
        switch statuses[model] {
        case .preparing, .downloading: return true
        default: return downloaded.contains(model)
        }
    }
    func status(for model: String) -> ModelStatus { statuses[model] ?? .notDownloaded }
    func servingModel(wanted: String, fallback: String?) -> String {
        TranscriptionModel.pickServing(wanted: wanted, fallback: fallback, isResident: isReady)
    }
    func select(_ model: String) {}
    func primeIfCold(_ model: String) {}

    func awaitReady(_ model: String) async -> Bool {
        let delay = world?.loadDelay() ?? 0.2
        let outcome = loadOutcome
        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            clockAfter(delay) {
                self.world?.resumed()
                switch outcome {
                case .becomesReady: self.statuses[model] = .ready; cont.resume(returning: true)
                case .endsNotResident: cont.resume(returning: false)   // stays .preparing, never resident
                case .none: cont.resume(returning: self.isReady(model))
                }
            }
        }
        world?.landed()
        return ready
    }

    func transcribeSamples(_ samples: [Float], model: String) async -> String? {
        world?.bump()
        let id = Int((samples.first ?? 1).rounded())
        let token = "w\(id)"
        world?.noteDecode(token: token, model: model)
        let delay = world?.decodeDelay() ?? 0.1
        let text = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            clockAfter(delay) { self.world?.resumed(); cont.resume(returning: token) }
        }
        world?.landed()
        return text
    }
    func transcribe(_ url: URL, model: String) async -> String? {
        // Unreached: `transcribeSamples` always returns the token, so the
        // file fallback never runs. Present for the protocol.
        nil
    }

    func startLiveDictation(model: String, onUpdate: @escaping @MainActor (String, Float) -> Void,
                            onFailure: (@MainActor () -> Void)?, onMicLost: (@MainActor () -> Void)?) -> Bool { false }
    func liveSamplesSnapshot(model: String) -> [Float] { [] }
    var liveConfirmedText: String { "" }
    var liveConfirmedEndSeconds: Double { 0 }
    func stopLiveDictation() {}

    private func clockAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        world?.schedule(delay, work)
    }
}

/// Residency as the modes read it; the stand-in is served directly.
@MainActor final class SimModels: ModelServing {
    var servingDictationModel: String?
    var servingContinuousModel: String?
    func downloadContinuousModelIfNeeded(retryFailed: Bool) -> Bool { false }
}

/// A field that applies landed text and runs the REAL `DeliveryVerifier.step`
/// across the world's re-read receipts (landed / notYet / unknown).
/// Nonisolated like the production sink; delivery happens on the main actor.
final class SimSink: TextSink, @unchecked Sendable {
    weak var world: SimHoldWorld?
    private(set) var field = ""

    func canDeliver() -> Deliverability { .ok }

    func deliver(_ text: String, onDeliveryFailure: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { deliverOnMain(text, onFailure: onDeliveryFailure) }
    }

    @MainActor private func deliverOnMain(_ text: String, onFailure: @escaping () -> Void) -> Bool {
        guard let world else { return true }
        world.bump()
        let delivering = world.finishedUtterance(text)
        world.deliveringUtterance = delivering
        // Only for this delivery's own turn: a notice after it is a late one.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if world.deliveringUtterance === delivering { world.deliveringUtterance = nil }
            }
        }
        world.finishedUtterance(text)?.typingSinkDelivered = true
        let receipt = world.chooseReceipt()
        if receipt == .landed {
            field += text
            world.finishedUtterance(text)?.landed = true
        }
        verify(text: text, receipt: receipt, attempt: 0, onFailure: onFailure)
        return true
    }

    /// One re-read at `DeliveryVerifier.delays[attempt]`, its verdict from the
    /// real `step`: confirm, retry, or fail (→ the copy box).
    @MainActor private func verify(text: String, receipt: DeliveryVerifier.Receipt, attempt: Int,
                                   onFailure: @escaping () -> Void) {
        guard let world else { return }
        world.schedule(DeliveryVerifier.delays[attempt]) {
            world.bump()
            switch DeliveryVerifier.step(receipt, attempt: attempt) {
            case .done:
                if receipt == .landed { world.finishedUtterance(text)?.typedConfirmed = true }
            case .retry:
                self.verify(text: text, receipt: receipt, attempt: attempt + 1, onFailure: onFailure)
            case .fail:
                onFailure()
            }
        }
    }
}

/// History / training / pace, attributed to the utterance by its text.
@MainActor final class SimRecords: DictationRecords {
    weak var world: SimHoldWorld?
    func addToHistory(_ text: String) { world?.finishedUtterance(text)?.inHistory = true }
    func addTrainingPair(_ text: String, audioURL: URL) { world?.finishedUtterance(text)?.trainingPaired = true }
    func recordPace(_ text: String, seconds: TimeInterval) {}
}

/// A one-chunk assistant: healthy at once, answers deterministically. Keeps
/// the assistant hold exercising the queue hand-off and overlay ownership.
@MainActor final class SimAssistant: AssistantService {
    weak var world: SimHoldWorld?
    func ensureHealthy() async -> Bool { true }
    var lastSpawnError: String? { nil }
    func apiKey(for provider: AssistantProvider) -> String { "" }
    func askStream(_ question: String, config: AssistantConfig, apiKey: String,
                   images: [AssistantClient.ImageInput]?,
                   history: [AssistantClient.HistoryItem]?) -> AsyncThrowingStream<String, Error> {
        world?.streamStarted(question: question)
        return AsyncThrowingStream { continuation in
            continuation.yield("answer")
            continuation.finish()
        }
    }
}

/// `awaitServing`'s yield between polls, as a wake on the world's virtual
/// clock instead of a real sleep — so the bounded-wait promise is checkable.
/// Main-actor isolated, so the wake is on the clock the moment the poll
/// sleeps and the resumed poll goes straight onto the main queue.
@MainActor final class WorldSleeper: Sleeper {
    weak var world: SimHoldWorld?
    func sleep(nanoseconds ns: UInt64) async {
        guard let world else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            world.schedule(Double(ns) / 1_000_000_000) { world.resumed(); cont.resume() }
        }
        world.landed()
    }
}

// MARK: - World helpers used by the fakes

extension SimHoldWorld {
    fileprivate func bump() { tick += 1 }
    /// A world wake resumed a parked task; `landed` when that task runs again.
    fileprivate func resumed() { inFlight += 1; tick += 1 }
    fileprivate func landed() { inFlight -= 1; tick += 1 }
    fileprivate func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        clock.after(delay) { [weak self] in self?.tick += 1; work() }
    }
    fileprivate func finishedUtterance(_ text: String) -> Utterance? { byFinished[text] }
}
