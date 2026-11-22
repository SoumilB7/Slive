import AVFoundation
import Combine
import Foundation
import SliveTestKit

/// Every registered mode under every user configuration we can reach on
/// fakes: the real `ModeRegistry`, `SessionCoordinator`, `HoldCapture`,
/// `ContinuousDictation` and `OverlayPresenter`, with the mic, the models,
/// the field and the records faked. A setting nobody on the team uses broke
/// a fresh install once; here each value meets every other (3-wise), and
/// the dimensions come from the registries, so a new mode, model, model
/// state, sink verdict or gesture joins the matrix by itself.
@MainActor
enum DictationConfigMatrixTests {
    typealias Trail = DictationModeTests.Trail

    static let suite = TestSuite(name: "Dictation config matrix") { t in
        print("[Dictation config matrix]")
        run(&t)
    }

    // MARK: - Dimensions

    /// One registered mode in one edition.
    struct ModeEntry: CustomStringConvertible {
        let edition: String
        let capabilities: Capabilities
        let action: HotkeyAction
        var description: String { "\(edition) \(action)" }
    }

    /// Full and Lite, each with exactly the modes its registry builds.
    static var modeEntries: [ModeEntry] {
        [("Full", Capabilities(hasServer: true)), ("Lite", Capabilities(hasServer: false))].flatMap { edition in
            World.registeredActions(edition.1).map {
                ModeEntry(edition: edition.0, capabilities: edition.1, action: $0)
            }
        }
    }

    /// The picked model's state as the modes see it.
    enum ModelState: CaseIterable {
        case ready, loading, downloading, notDownloaded, failed, coolingDown

        var status: ModelStatus {
            switch self {
            case .ready: return .ready
            case .loading: return .preparing("Loading")
            case .downloading: return .downloading(0.4)
            case .notDownloaded: return .notDownloaded
            case .failed, .coolingDown: return .failed("Timed out")
            }
        }

        /// On disk (a download running doesn't count yet).
        var isDownloaded: Bool { self != .notDownloaded && self != .downloading }
    }

    /// Every `ModelStatus` has a state here — a new status fails to compile
    /// until the matrix covers it.
    static func state(covering status: ModelStatus) -> ModelState {
        switch status {
        case .ready: return .ready
        case .preparing: return .loading
        case .downloading: return .downloading
        case .notDownloaded: return .notDownloaded
        case .failed: return .failed
        }
    }

    /// The field's verdicts. Same rule: a new `Deliverability` case fails
    /// to compile in `sinkIndex` until it's listed here.
    static let sinks: [Deliverability] = [.ok, .blocked(note: "Allow Accessibility"), .blocked(note: nil), .unknown]

    static func sinkIndex(_ verdict: Deliverability) -> Int {
        switch verdict {
        case .ok: return 0
        case .blocked(let note): return note == nil ? 2 : 1
        case .unknown: return 3
        }
    }

    /// How the shortcut is used, ending included.
    enum Gesture: CaseIterable {
        case holdRelease
        case toggleRelease
        /// fn-hold matured, then fn-fn: the hold is a false start, aborted;
        /// the toggle it became records and is released.
        case holdThenDoubleTap
        /// Tap, tap: a toggle session started and stopped at once.
        case tapTap
        /// Released before the hold delay: nothing at all.
        case tooShortTap
        /// ✕ while the release decodes (the stuck pill or the loading box).
        case dismissAfterRelease
        /// A second hold right after the first release.
        case twoHolds
        /// A toggle session running, then the next mode's hold takes over.
        case switchMode
    }

    /// What the mic delivers.
    enum Input: CaseIterable {
        case speech, digitalSilence, roomNoise, blip, micDenied, micFails
    }

    enum Decoded: CaseIterable { case words, empty }

    /// One combination, decoded from a covering-array row.
    struct Config: CustomStringConvertible {
        var mode: ModeEntry
        var model: String
        var state: ModelState
        var previousServes: Bool
        var autoInsert: Bool
        var echoCancellation: Bool
        var sink: Deliverability
        var captureEdits: Bool
        var gesture: Gesture
        var holdDelay: Double
        var tier: SpeedTier
        var input: Input
        var decoded: Decoded
        var attachScreenshot: Bool

        var description: String {
            "\(mode) model=\(model) \(state) prev=\(previousServes) autoInsert=\(autoInsert) echo=\(echoCancellation) "
                + "sink=\(sink) training=\(captureEdits) \(gesture) delay=\(holdDelay) \(tier) \(input) \(decoded) "
                + "shot=\(attachScreenshot)"
        }
    }

    static let fineTune = "slive-ft-matrix"
    /// Every model a user can pick for dictation, plus an installed fine-tune.
    static var models: [String] {
        ModelCatalog.all.filter { $0.uses.contains(.dictation) }.map(\.id) + [fineTune]
    }
    static let bools = [false, true]
    static let delays = [0.0, 0.3]

    /// The dimensions, each a list of values (as `Config` setters).
    static var dimensions: [(name: String, values: [(inout Config) -> Void])] {
        [
            ("mode", modeEntries.map { v in { $0.mode = v } }),
            ("model", models.map { v in { $0.model = v } }),
            ("model state", ModelState.allCases.map { v in { $0.state = v } }),
            ("previous model serving", bools.map { v in { $0.previousServes = v } }),
            ("type at cursor", bools.map { v in { $0.autoInsert = v } }),
            ("echo cancellation", bools.map { v in { $0.echoCancellation = v } }),
            ("field", sinks.map { v in { $0.sink = v } }),
            ("save training data", bools.map { v in { $0.captureEdits = v } }),
            ("gesture", Gesture.allCases.map { v in { $0.gesture = v } }),
            ("hold delay", delays.map { v in { $0.holdDelay = v } }),
            ("speed tier", SpeedTier.allCases.map { v in { $0.tier = v } }),
            ("mic input", Input.allCases.map { v in { $0.input = v } }),
            ("decoded text", Decoded.allCases.map { v in { $0.decoded = v } }),
            ("attach screenshot", bools.map { v in { $0.attachScreenshot = v } }),
        ]
    }

    /// The values every dimension then overwrites.
    static let base = Config(
        mode: ModeEntry(edition: "Full", capabilities: Capabilities(hasServer: true), action: .dictate), model: ModelCatalog.defaultDictation, state: .ready, previousServes: false,
        autoInsert: true, echoCancellation: false, sink: .ok, captureEdits: true, gesture: .holdRelease,
        holdDelay: 0, tier: .relaxed, input: .speech, decoded: .words, attachScreenshot: false)

    /// 3-wise: every three values of any three settings meet in some run.
    static let strength = 3

    // MARK: - Run

    private static func run(_ t: inout Checks) {
        let dims = dimensions
        let sizes = dims.map(\.values.count)
        let rows = CoveringArray.rows(sizes, strength: strength)
        t.check(CoveringArray.covers(rows, sizes, strength: strength),
                "\(rows.count) runs cover every \(strength)-way combination of \(dims.count) settings "
                    + "(\(sizes.reduce(1, *)) in the full product)")
        t.check(CoveringArray.covers(CoveringArray.rows([3, 2, 4], strength: 2), [3, 2, 4], strength: 2)
                && CoveringArray.rows([3, 2, 4], strength: 3).count == 24,
                "the covering-array builder covers small matrices (and builds the product at full strength)")
        t.check(Set(modeEntries.map(\.action)) == Set(HotkeyAction.allCases.filter {
            $0.spec.isAvailable(in: Capabilities(hasServer: true)) }),
                "the matrix runs every action Full registers")
        t.check(ModelState.allCases.map(\.status).map(state(covering:)).count == ModelState.allCases.count
                && sinks.map(sinkIndex) == Array(sinks.indices),
                "every model status and field verdict is a matrix value")

        // The delivery invariants only bite on runs that should deliver, which
        // the matrix above makes rare (speech × words × a usable model): a
        // second, all-pairs matrix holds those three to delivering values.
        let delivering = dims.map { dim -> [(inout Config) -> Void] in
            switch dim.name {
            case "model state": return [{ $0.state = .ready }, { $0.state = .loading }]
            case "mic input": return [{ $0.input = .speech }]
            case "decoded text": return [{ $0.decoded = .words }]
            default: return dim.values
            }
        }
        let deliveringRows = CoveringArray.rows(delivering.map(\.count), strength: 2)
        let configs = rows.map { row -> Config in
            var config = base
            for (d, v) in row.enumerated() { dims[d].values[v](&config) }
            return config
        } + deliveringRows.map { row -> Config in
            var config = base
            for (d, v) in row.enumerated() { delivering[d][v](&config) }
            return config
        }

        var failures: [String: [String]] = [:]
        var order: [String] = []
        var delivered: [HotkeyAction: Int] = [:]
        var fingerprints: [String] = []
        for config in configs {
            let world = World(config)
            for (name, ok) in world.runAndJudge() {
                if !order.contains(name) { order.append(name) }
                if !ok { failures[name, default: []].append(config.description) }
            }
            if world.deliverable { delivered[config.mode.action, default: 0] += 1 }
            fingerprints.append(world.fingerprint)
        }
        // The runs settle on the world's own state and virtual time, so a
        // second pass must repeat every one exactly, however busy the Mac.
        let replayed = configs.indices.filter { i in
            let world = World(configs[i])
            _ = world.runAndJudge()
            return world.fingerprint != fingerprints[i]
        }
        t.check(replayed.isEmpty, "every run replays exactly (verdicts, trail, overlay states, field)",
                "\(replayed.count)/\(configs.count) differ, e.g. "
                    + replayed.prefix(3).map { configs[$0].description }.joined(separator: " | "))
        checkSecureInputIsTheWorlds(&t)
        t.check(modeEntries.allSatisfy { delivered[$0.action, default: 0] >= 5 },
                "plus \(deliveringRows.count) delivering runs (all-pairs); every mode delivers words in 5+ runs",
                delivered.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
        for name in order {
            let failed = failures[name] ?? []
            t.check(failed.isEmpty, name,
                    "\(failed.count)/\(configs.count) runs, e.g. " + failed.prefix(3).joined(separator: " | "))
        }
    }

    /// The hold's secure-input refusal answers from the world, not from
    /// this Mac: with the screen locked, loginwindow holds secure input and
    /// every dictate hold here was refused ("Secure input is on in
    /// loginwindow"), which read as lost words in 5 of 515 runs.
    private static func checkSecureInputIsTheWorlds(_ t: inout Checks) {
        let off = World(base)
        _ = off.runAndJudge()
        let notice = "Secure input is on in Terminal"
        let on = World(base, secureInput: notice)
        _ = on.runAndJudge()
        let offLog = off.trail.all, onLog = on.trail.all
        t.check(offLog.contains("typed hello world") && offLog.contains("history hello world")
                    && onLog == ["box \(notice)"] && on.recorder.options.isEmpty,
                "secure input is the run's, never this Mac's: off, the dictation types; on, the hold is refused "
                    + "with its notice and nothing records",
                "off: \(offLog) · on: \(onLog)")
    }

    // MARK: - One run

    @MainActor final class World {
        let config: Config
        let trail = Trail()
        let settings = World.settings
        let clock = ManualScheduler()
        /// Time for the work between gestures: the model wait's poll and the
        /// live typist's steps (see `settle`).
        let workClock = ManualScheduler()
        let recorder: Recorder
        let speech: Speech
        let models: Models
        let sink: DictationModeTests.FakeSink
        let assistant = DictationModeTests.FakeAssistant()
        let presenter: OverlayPresenter
        let session: SessionCoordinator
        let queue = DictationQueue()
        let work: InFlightWork
        let registry: ModeRegistry
        let continuous: ContinuousDictation
        let sleeper: VirtualSleeper
        let lanes: TypistLanes
        private var states: [OverlayState] = []
        private var watch: AnyCancellable?
        private var finished: Set<Task<Void, Never>> = []
        private var watched: Set<Task<Void, Never>> = []
        var faults = 0
        /// The run should have delivered words (set by `runAndJudge`).
        private(set) var deliverable = false
        /// What the run did, for the replay check: verdicts, the trail (less
        /// the screenshot, taken on a background task at its own moment),
        /// every overlay state and the field.
        private(set) var fingerprint = ""

        /// One in-memory Settings for every run (each run sets every value
        /// it varies; the flows never write it): its init reads the real
        /// login-item state, ~50 ms a time.
        static let settings = Settings(store: InMemoryStore())

        /// The actions `ModeRegistry.standard` builds for `capabilities`.
        static func registeredActions(_ capabilities: Capabilities) -> [HotkeyAction] {
            World(base, capabilities: capabilities).registry.actions
        }

        convenience init(_ config: Config, secureInput: String? = nil) {
            self.init(config, capabilities: config.mode.capabilities, secureInput: secureInput)
        }

        /// `secureInput`: what the hold's secure-input check answers (nil:
        /// off). Fixed per run, never this Mac's: a locked screen gives
        /// loginwindow secure input, which refused every dictate hold.
        init(_ config: Config, capabilities: Capabilities, secureInput: String? = nil) {
            self.config = config
            let s = settings
            s.whisperModel = config.model
            let continuousPick = ModelCatalog.descriptor(config.model).map { $0.uses.contains(.continuous) } ?? true
            s.continuousModel = continuousPick ? config.model : ModelCatalog.defaultContinuous
            s.autoInsert = config.autoInsert
            s.echoCancellation = config.echoCancellation
            s.captureEdits = config.captureEdits
            s.holdActivationDelay = config.holdDelay
            s.speedTier = config.tier.rawValue
            s.continuousTypeCPS = 1000   // instant: no pacing to wait out
            var assistantConfig = s.assistantConfig
            assistantConfig.attachScreenshot = config.attachScreenshot
            s.assistantConfig = assistantConfig

            let heard = config.input == .speech && config.decoded == .words ? "hello world" : ""
            let picks = [s.whisperModel, s.continuousModel]
            let previous = ModelCatalog.all.map(\.id).first { !picks.contains($0) }!
            speech = Speech(states: Dictionary(picks.map { ($0, config.state) }, uniquingKeysWith: { a, _ in a }),
                            transcript: heard, liveFails: config.input == .micFails)
            models = Models(speech: speech, settings: s)
            if config.previousServes {
                models.servingDictationModel = previous
                models.servingContinuousModel = previous
            }
            recorder = Recorder(input: config.input, trail: trail)
            sink = DictationModeTests.FakeSink(trail: trail)
            sink.verdict = config.sink
            let model = AudioModel()
            let surface = OverlayStateTests.FakeSurface(model: model)
            presenter = OverlayPresenter(model: model, scheduler: clock) { surface }
            session = SessionCoordinator(scheduler: clock, holdDelay: { s.holdActivationDelay })
            work = InFlightWork(queue: queue, session: session)
            let lanes = TypistLanes(clock: workClock)
            self.lanes = lanes
            continuous = ContinuousDictation(speech: speech, sink: sink, settings: s,
                                             makeTypist: { LiveTypist(sink: $0, queue: lanes.make()) })
            sleeper = VirtualSleeper(clock: workClock)
            let clockRef = clock
            let trail = self.trail
            let mic: AVAuthorizationStatus = config.input == .micDenied ? .denied : .authorized
            var reported: () -> Void = {}
            let ctx = ModeContext(
                recorder: recorder, speech: speech, models: models, presenter: presenter,
                queue: queue, session: session, work: work, settings: s,
                records: Records(trail: trail, settings: s, capabilities: capabilities),
                report: FaultSink { _, _, _, _, _, _, _ in reported() },
                typing: sink, typingBlockedNote: { "Allow Accessibility" },
                captureOptions: { CaptureOptions.from(s) }, cue: { trail.add("cue \($0)") },
                micAuthorization: { mic }, secureInputNotice: { secureInput }, wakeFrontApp: {},
                nowProvider: { MainActor.assumeIsolated { clockRef.now } }, sleeper: sleeper)
            registry = ModeRegistry.standard(ctx, continuous: continuous, assistant: assistant,
                                             capabilities: capabilities,
                                             screenshot: { trail.add("screenshot"); return ("image/png", "AA==") })
            session.handler = registry
            reported = { [weak self] in self?.faults += 1 }
            watch = model.$state.sink { [weak self] state in
                guard let self else { return }
                if self.states.last != state {
                    self.states.append(state)
                    if case .result(let r) = state { self.trail.add(r.answer == nil ? "box \(r.text)" : "answer \(r.text)") }
                }
            }
        }

        // MARK: Gestures

        private var action: HotkeyAction { config.mode.action }
        private let tail = SessionCoordinator.postReleaseCaptureSeconds

        /// What the user says while capturing: the stream hears it live (the
        /// hold modes get it from the recorder at release).
        private func speak() {
            if action == .stream, !speech.transcript.isEmpty { speech.liveUpdate?(speech.transcript, 0.3) }
        }

        private func hold() {
            session.keyDown(action)
            clock.advance(by: config.holdDelay)
            speak()
            clock.advance(by: 1.5)
            session.keyUp()
            clock.advance(by: tail)
        }

        /// The ✕, as `AppDelegate.dismissOverlay` wires it.
        private func dismissOverlay() {
            work.cancelRequest()
            session.endToggle()
            registry.dismissAll()
            presenter.dismiss()
        }

        private func perform(_ gesture: Gesture) {
            switch gesture {
            case .holdRelease:
                hold()
            case .toggleRelease:
                session.toggleTapped(action)
                speak()
                clock.advance(by: 2)
                session.toggleTapped(action)
                clock.advance(by: tail)
            case .holdThenDoubleTap:
                session.keyDown(action)
                clock.advance(by: config.holdDelay + 0.05)
                session.keyUp()
                clock.advance(by: tail / 2)
                session.toggleTapped(action)
                speak()
                clock.advance(by: 2)
                session.toggleTapped(action)
                clock.advance(by: tail)
            case .tapTap:
                session.toggleTapped(action)
                session.toggleTapped(action)
                clock.advance(by: tail)
            case .tooShortTap:
                session.keyDown(action)
                session.keyUp()
                clock.advance(by: 1)
            case .dismissAfterRelease:
                hold()
                dismissOverlay()
            case .switchMode:
                let other = registry.actions.first { $0 != action } ?? action
                session.toggleTapped(action)
                speak()
                clock.advance(by: 1)
                session.keyDown(other)
                clock.advance(by: config.holdDelay + 1.5)
                session.keyUp()
                clock.advance(by: tail)
            case .twoHolds:
                hold()
                // A re-press is never faster than one main-actor turn: the
                // release's task has started by then. Waited for, not timed: a
                // stream's start is its final pass taking the session (else
                // the re-press finds it live and does nothing).
                let realLimit = Date().addingTimeInterval(Self.realWorkLimit)
                repeat { Self.drainMainQueue() } while action == .stream && continuous.isActive && Date() < realLimit
                hold()
            }
        }

        // MARK: Settling

        /// The in-flight request (an assistant answer) has returned.
        private var requestDone: Bool {
            guard let request = work.request else { return true }
            if !watched.contains(request) {
                watched.insert(request)
                Task { @MainActor [weak self] in
                    await request.value
                    self?.finished.insert(request)
                }
            }
            return finished.contains(request)
        }

        private var quiet: Bool {
            guard queue.isEmpty, requestDone, !registry.isCapturing else { return false }
            switch presenter.state {
            case .listening, .transcribing: return false
            case .idle, .result: return !(presenter.state.result?.isStreaming ?? false)
            }
        }

        /// Run the world until nothing is in flight. Done is decided by the
        /// world, never by an idle-looking run loop (main-actor resumes hop
        /// through the cooperative pool, so idleness depends on load): the
        /// queue drained, no answer or final pass running, the overlay at
        /// rest. The overlay and gesture clock stays frozen, as it was; the
        /// model wait's poll and the typist's steps run on `workClock`,
        /// stepped only when a round moved nothing, so a slow hop costs
        /// real time, not virtual time. False past `settleSeconds` of work
        /// time (a wait that never ends) or `realWorkLimit` of real time.
        private func settle() -> Bool {
            let end = workClock.now.addingTimeInterval(Self.settleSeconds)
            let realLimit = Date().addingTimeInterval(Self.realWorkLimit)
            while true {
                let before = progress
                Self.drainMainQueue()
                lanes.releaseForeign()
                if done { return true }
                guard Date() < realLimit else { return false }
                guard progress == before else { continue }
                if let due = workClock.nextDue {
                    guard due <= end else { return false }
                    workClock.advanceToNext()
                } else {
                    usleep(20)   // real work (an answer, a final pass) is on its way
                }
            }
        }

        /// Virtual work time a run may take to settle: 300 model-wait polls;
        /// the flows need a handful.
        static let settleSeconds: TimeInterval = 60
        /// A safety net for real work only: it takes milliseconds, so this
        /// only ends a run whose task truly hung.
        static let realWorkLimit: TimeInterval = 30

        /// Nothing left to run: `quiet`, and no stream final pass running or
        /// typist step waiting to be released (the final pass's flush runs on
        /// the cooperative pool, so it is invisible to the queue and overlay).
        private var done: Bool { quiet && !continuous.isFinishing && !lanes.hasForeign }

        /// Moves on every fake call, typist step, overlay change and wake.
        private var progress: Int {
            trail.all.count + states.count + speech.calls + lanes.steps + sleeper.wakes
        }

        /// One pass over the main queue: every job queued so far, up to a
        /// marker. A pacing step only: a resumed task reaches the main queue
        /// via the cooperative pool (up to ~50 passes later under load), so an
        /// empty pass proves nothing and `settle` never ends on one.
        static func drainMainQueue() {
            let target = markers + 1
            DispatchQueue.main.async { MainActor.assumeIsolated { markers += 1 } }
            while markers < target { _ = CFRunLoopRunInMode(.defaultMode, 0, true) }
        }
        private static var markers = 0

        // MARK: Judging

        /// Run the gesture to the end, then every invariant as (name, held).
        func runAndJudge() -> [(String, Bool)] {
            perform(config.gesture)
            let settled = settle()
            let endState = presenter.state
            clock.advance(by: 60)   // every collapse and fade timer
            let finalState = presenter.state
            let log = trail.all
            func count(_ prefix: String) -> Int { log.filter { $0.hasPrefix(prefix) }.count }

            let text = "hello world"
            let answer = "aello world"   // FakeAssistant: "a" + the question minus its first letter
            let history = log.filter { $0.hasPrefix("history ") }
            let typedDictations = count("typed ")
            let fieldTyped = !sink.field.isEmpty
            let typed = typedDictations > 0 || fieldTyped
            let boxes = states.filter { $0.result.map { $0.answer == nil && $0.text == text } ?? false }.count
            let answers = states.filter { $0.result.map { $0.answer?.streaming == false && $0.text == answer } ?? false }.count
            let training = log.filter { $0.hasPrefix("training ") }

            let c = config
            let records = action != .stream
            let usable: Bool
            switch action {
            case .stream: usable = c.state == .ready || c.previousServes
            default: usable = c.state == .ready || c.state == .loading || c.previousServes
            }
            let heard = c.input == .speech && c.decoded == .words
            let releases: Int
            switch c.gesture {
            case .tooShortTap: releases = 0
            case .dismissAfterRelease: releases = action == .dictate ? 1 : 0
            case .twoHolds, .switchMode: releases = 2
            default: releases = 1
            }
            let deliverable = heard && usable && releases > 0 && c.gesture != .switchMode
            self.deliverable = deliverable
            let gate = AppRecords.savesTraining(capabilities: c.mode.capabilities, captureEdits: c.captureEdits,
                                                overLimit: false)
            // Only dictations save training pairs (a mode switch may hold one of
            // each), and only the pick's own: a previous model serving meanwhile
            // isn't the user's model.
            let pickDecodes = c.state == .ready || (c.state == .loading && !c.previousServes)
            let trainingCount = c.gesture == .switchMode ? (gate || training.isEmpty)
                : (action == .dictate && gate && pickDecodes ? training.count == history.count : training.isEmpty)

            var out: [(String, Bool)] = []
            out.append(("no hang: every run settles with nothing capturing or toggled on",
                        settled && !registry.isCapturing && !recorder.isRecording
                            && session.toggleActive == nil && !session.isSessionLive))
            out.append(("the queue drains and the latency assertion is released",
                        queue.isEmpty && !work.holdsDictationActivity))
            out.append(("the overlay ends idle or on a result, and idle once its timers run",
                        (endState == .idle || endState.result != nil) && finalState == .idle))
            out.append(("every recording's WAV is removed",
                        recorder.created.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }))
            out.append(("text never lands both typed and in a copy box", !(typed && boxes > 0)))
            out.append(("history holds only delivered text, at most one entry per release",
                        history.count <= releases
                            && history.allSatisfy {
                                c.gesture == .switchMode ? ($0 == "history \(text)" || $0 == "history \(answer)")
                                    : $0 == "history \(action == .assist ? answer : text)" }))
            switch action {
            case .dictate:
                out.append(("spoken words are never lost (dictate: every release in history, shown or typed)",
                            !deliverable || (history.count == releases && typedDictations + boxes >= 1)))
                out.append(("type at cursor off never asks the field (dictate)", c.autoInsert || sink.delivered == 0))
                out.append(("type first: the text is typed or boxed before any bookkeeping (dictate)",
                            { () -> Bool in
                                // (Not typed with a newer session on the overlay: history only, by design.
                                // A mode switch's stream boxes the same words later, Type at cursor off.)
                                guard c.gesture != .switchMode || c.autoInsert,
                                      let delivered = log.firstIndex(where: { $0.hasPrefix("typed ") || $0.hasPrefix("box ") })
                                else { return true }
                                return delivered < (log.firstIndex { $0.hasPrefix("history ") } ?? .max)
                            }()))
            case .stream:
                out.append(("spoken words are never lost (stream: typed live or boxed, and in history)",
                            !deliverable || (history.count == releases && (fieldTyped || boxes >= 1))))
                let plainBoxes = states.filter { $0.result.map { $0.answer == nil && $0.text == text && $0.note == nil }
                    ?? false }.count
                out.append(("type at cursor off: a stream's words land in the copy box, without a note (stream)",
                            c.autoInsert || !deliverable || plainBoxes >= 1))
                out.append(("the stream's pill: the pen when it types at the cursor, the waveform when it can't",
                            c.gesture == .switchMode
                                || !states.contains(.listening(c.autoInsert ? .dictation : .live))))
            case .assist:
                out.append(("spoken questions get an answer (assist)", !deliverable || answers >= 1))
                out.append(("an assistant answer is never typed", c.gesture == .switchMode
                            || (sink.delivered == 0 && !fieldTyped && sink.streamsBegun == 0)))
            }
            out.append(("type at cursor off ⇒ zero keystrokes in every mode (nothing typed, no backspace, "
                            + "the field never asked or claimed)",
                        c.autoInsert || (typedDictations == 0 && !fieldTyped && sink.replaces == 0
                                         && sink.delivered == 0 && sink.streamsBegun == 0)))
            out.append(("a refused field never receives text",
                        c.sink.allowsDelivery || (typedDictations == 0 && !fieldTyped)))
            out.append(("training pairs only when this build trains and saving is on, while the WAV exists",
                        training.allSatisfy { $0.hasSuffix("wav=true") } && trainingCount))
            out.append(("echo cancellation reaches every recording",
                        !records || recorder.options.allSatisfy { $0.echoCancellation == c.echoCancellation }))
            out.append(("a fault is reported only when the mic fails", faults == 0 || c.input == .micFails))
            out.append(("the screen is captured only for an assistant set to attach it",
                        count("screenshot") == 0
                            || ((action == .assist || c.gesture == .switchMode) && c.attachScreenshot)))
            out.append(("a too-short tap does nothing at all",
                        c.gesture != .tooShortTap || (recorder.options.isEmpty && speech.liveStarts == 0
                                                       && history.isEmpty && states.allSatisfy { $0 == .idle })))
            let problem = states.contains { s in
                guard let r = s.result else { return false }
                return r.text != text && r.text != answer && !r.text.isEmpty
            }
            out.append(("an unusable model says why instead of fading",
                        !(heard && !usable && releases > 0 && c.gesture != .dismissAfterRelease) || problem))
            for url in recorder.created { try? FileManager.default.removeItem(at: url) }
            fingerprint = [out.map { "\($0.0)=\($0.1)" }.joined(separator: ";"),
                           log.filter { $0 != "screenshot" }.joined(separator: ";"),
                           states.map { "\($0)" }.joined(separator: ";"), sink.field].joined(separator: "|")
            return out
        }
    }

    // MARK: - Fakes

    /// The mic: a new WAV per recording (removed by its owner), samples per `input`.
    final class Recorder: Recording {
        let input: Input
        let trail: Trail
        private(set) var isRecording = false
        private(set) var options: [CaptureOptions] = []
        private(set) var created: [URL] = []

        init(input: Input, trail: Trail) {
            self.input = input
            self.trail = trail
        }

        func start(_ options: CaptureOptions) -> Bool {
            self.options.append(options)
            guard input != .micFails else { return false }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("slive-matrix-\(UUID().uuidString).wav")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            created.append(url)
            isRecording = true
            return true
        }

        func stop() -> RecordedAudio {
            isRecording = false
            return RecordedAudio(url: created.last, samples: Self.samples(input))
        }

        static func samples(_ input: Input) -> [Float] {
            switch input {
            case .speech, .micDenied, .micFails: return (0..<16_000).map { Float(sin(Double($0) * 0.17) * 0.3) }
            case .digitalSilence: return [Float](repeating: 0, count: 16_000)
            case .roomNoise: return (0..<16_000).map { Float(sin(Double($0) * 1.3) * 0.002) }
            case .blip: return (0..<3_200).map { Float(sin(Double($0) * 0.17) * 0.3) }
            }
        }
    }

    /// On-device speech with a state per model: loading becomes ready when
    /// awaited; a failed load fails again and cools down.
    final class Speech: DictationSpeech {
        var states: [String: ModelState]
        let transcript: String
        let liveFails: Bool
        var liveUpdate: (@MainActor (String, Float) -> Void)?
        private(set) var liveStarts = 0
        /// Every call: the settle loop's sign that a task moved.
        private(set) var calls = 0

        init(states: [String: ModelState], transcript: String, liveFails: Bool) {
            self.states = states
            self.transcript = transcript
            self.liveFails = liveFails
        }

        func state(_ model: String) -> ModelState {
            calls += 1
            return states[model] ?? .ready
        }
        func isReady(_ model: String) -> Bool { state(model) == .ready }
        /// As `TranscriptionModel`: resident, loading, or on disk and not cooling down.
        func canBecomeReady(_ model: String) -> Bool { [.ready, .loading, .failed].contains(state(model)) }
        func status(for model: String) -> ModelStatus { state(model).status }
        func servingModel(wanted: String, fallback: String?) -> String {
            TranscriptionModel.pickServing(wanted: wanted, fallback: fallback, isResident: isReady)
        }
        func select(_ model: String) {}
        func primeIfCold(_ model: String) {}
        func awaitReady(_ model: String) async -> Bool {
            switch state(model) {
            case .loading: states[model] = .ready
            case .failed: states[model] = .coolingDown
            default: break
            }
            return isReady(model)
        }
        func transcribeSamples(_ samples: [Float], model: String) async -> String? {
            calls += 1
            return isReady(model) ? transcript : nil
        }
        func transcribe(_ url: URL, model: String) async -> String? {
            await awaitReady(model) ? transcript : nil
        }
        func startLiveDictation(model: String,
                                onUpdate: @escaping @MainActor (String, Float) -> Void,
                                onFailure: (@MainActor () -> Void)?,
                                onMicLost: (@MainActor () -> Void)?) -> Bool {
            liveStarts += 1
            calls += 1
            guard !liveFails else { return false }
            liveUpdate = onUpdate
            return true
        }
        func liveSamplesSnapshot(model: String) -> [Float] {
            calls += 1
            return Recorder.samples(.speech)
        }
        var liveConfirmedText: String { "" }
        var liveConfirmedEndSeconds: Double { 0 }
        func stopLiveDictation() {
            calls += 1
            liveUpdate = nil
        }
    }

    /// The model wait's poll as a wake on the run's work clock, so a wait
    /// costs no real time and only moves when `settle` steps that clock.
    @MainActor final class VirtualSleeper: Sleeper {
        let clock: ManualScheduler
        private(set) var wakes = 0
        init(clock: ManualScheduler) { self.clock = clock }

        func sleep(nanoseconds: UInt64) async {
            await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
                clock.after(Double(nanoseconds) / 1_000_000_000) { [weak self] in
                    self?.wakes += 1
                    wake.resume()
                }
            }
        }
    }

    /// The live typists' queues, one per stream session: steps run on the
    /// main thread in arrival order, timed steps on the virtual clock.
    final class TypistLanes: @unchecked Sendable {
        private let clock: ManualScheduler
        private let lock = NSLock()
        /// Steps sent from off the main thread (the final pass's flush runs
        /// on the cooperative pool): held for the settle loop, which runs
        /// them only once the world is otherwise still, so their arrival
        /// time never decides where they land.
        private var foreign: [(lane: Lane, work: @Sendable () -> Void)] = []
        /// Steps run so far (main thread only).
        private(set) var steps = 0

        init(clock: ManualScheduler) { self.clock = clock }

        func make() -> Lane { Lane(owner: self) }

        var hasForeign: Bool {
            lock.lock(); defer { lock.unlock() }
            return !foreign.isEmpty
        }

        /// Move the off-main steps onto their lanes, in arrival order.
        func releaseForeign() {
            lock.lock()
            let arrived = foreign
            foreign = []
            lock.unlock()
            for step in arrived { step.lane.enqueue(step.work) }
        }

        final class Lane: TypistQueue, @unchecked Sendable {
            private unowned let owner: TypistLanes
            private var ready: [@Sendable () -> Void] = []
            private var draining = false

            init(owner: TypistLanes) { self.owner = owner }

            func run(_ work: @escaping @Sendable () -> Void) {
                guard Thread.isMainThread else {
                    owner.lock.lock()
                    owner.foreign.append((self, work))
                    owner.lock.unlock()
                    return
                }
                enqueue(work)
            }

            /// Only a step schedules a step, and steps run on the main thread.
            func run(after seconds: TimeInterval, _ item: DispatchWorkItem) {
                MainActor.assumeIsolated {
                    _ = owner.clock.after(seconds) { [weak self] in
                        self?.enqueue { if !item.isCancelled { item.perform() } }
                    }
                }
            }

            /// Serial: a step queued by a running step waits for it to end.
            fileprivate func enqueue(_ work: @escaping @Sendable () -> Void) {
                ready.append(work)
                guard !draining else { return }
                draining = true
                while !ready.isEmpty {
                    let next = ready.removeFirst()
                    owner.steps += 1
                    next()
                }
                draining = false
            }
        }
    }

    /// Residency as the modes see it; the continuous auto-download follows
    /// `ModelResidency.fetchesContinuous`.
    final class Models: ModelServing {
        var servingDictationModel: String?
        var servingContinuousModel: String?
        private(set) var fetchStarted = false
        private let speech: Speech
        private let settings: Settings

        init(speech: Speech, settings: Settings) {
            self.speech = speech
            self.settings = settings
        }

        func downloadContinuousModelIfNeeded(retryFailed: Bool) -> Bool {
            let model = settings.continuousModel
            guard !speech.state(model).isDownloaded else { return false }
            switch ModelResidency.fetchesContinuous(status: speech.status(for: model), retryFailed: retryFailed) {
            case .running: return true
            case .no: return false
            case .start: fetchStarted = true; return true
            }
        }
    }

    /// The records, through the app's own training gate (never over the size cap here).
    struct Records: DictationRecords {
        let trail: Trail
        let settings: Settings
        let capabilities: Capabilities

        func addToHistory(_ text: String) { trail.add("history \(text)") }
        func addTrainingPair(_ text: String, audioURL: URL) {
            guard AppRecords.savesTraining(capabilities: capabilities, captureEdits: settings.captureEdits,
                                           overLimit: false) else { return }
            trail.add("training \(text) wav=\(FileManager.default.fileExists(atPath: audioURL.path))")
        }
        func recordPace(_ text: String, seconds: TimeInterval) { trail.add("pace \(text)") }
    }
}
