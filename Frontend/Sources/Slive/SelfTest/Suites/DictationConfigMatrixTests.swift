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
        for config in configs {
            let world = World(config)
            for (name, ok) in world.runAndJudge() {
                if !order.contains(name) { order.append(name) }
                if !ok { failures[name, default: []].append(config.description) }
            }
            if world.deliverable { delivered[config.mode.action, default: 0] += 1 }
        }
        t.check(modeEntries.allSatisfy { delivered[$0.action, default: 0] >= 5 },
                "plus \(deliveringRows.count) delivering runs (all-pairs); every mode delivers words in 5+ runs",
                delivered.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
        for name in order {
            let failed = failures[name] ?? []
            t.check(failed.isEmpty, name,
                    "\(failed.count)/\(configs.count) runs, e.g. " + failed.prefix(3).joined(separator: " | "))
        }
    }

    // MARK: - One run

    @MainActor final class World {
        let config: Config
        let trail = Trail()
        let settings = World.settings
        let clock = ManualScheduler()
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
        private var states: [OverlayState] = []
        private var watch: AnyCancellable?
        private var finished: Set<Task<Void, Never>> = []
        private var watched: Set<Task<Void, Never>> = []
        var faults = 0
        /// The run should have delivered words (set by `runAndJudge`).
        private(set) var deliverable = false

        /// One in-memory Settings for every run (each run sets every value
        /// it varies; the flows never write it): its init reads the real
        /// login-item state, ~50 ms a time.
        static let settings = Settings(store: InMemoryStore())

        /// The actions `ModeRegistry.standard` builds for `capabilities`.
        static func registeredActions(_ capabilities: Capabilities) -> [HotkeyAction] {
            World(base, capabilities: capabilities).registry.actions
        }

        convenience init(_ config: Config) { self.init(config, capabilities: config.mode.capabilities) }

        init(_ config: Config, capabilities: Capabilities) {
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
            continuous = ContinuousDictation(speech: speech, sink: sink, settings: s)
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
                micAuthorization: { mic })
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
                // release's task has started by then.
                RunLoop.main.run(mode: .default, before: Date())
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

        /// Spin the main run loop until nothing is in flight (and stays so
        /// for a few turns — the stream's final pass is an untracked task).
        private func settle() -> Bool {
            let deadline = Date().addingTimeInterval(3)
            var calm = 0
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.0005))
                calm = quiet ? calm + 1 : 0
                if calm >= 4 { return true }
            }
            return false
        }

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
            // Only dictations save training pairs (a mode switch may hold one of each).
            let trainingCount = c.gesture == .switchMode ? (gate || training.isEmpty)
                : (action == .dictate && gate ? training.count == history.count : training.isEmpty)

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
                                // (Not typed with a newer session on the overlay: history only, by design.)
                                guard let delivered = log.firstIndex(where: { $0.hasPrefix("typed ") || $0.hasPrefix("box ") })
                                else { return true }
                                return delivered < (log.firstIndex { $0.hasPrefix("history ") } ?? .max)
                            }()))
            case .stream:
                out.append(("spoken words are never lost (stream: typed live or boxed, and in history)",
                            !deliverable || (history.count == releases && (fieldTyped || boxes >= 1))))
            case .assist:
                out.append(("spoken questions get an answer (assist)", !deliverable || answers >= 1))
                out.append(("an assistant answer is never typed", c.gesture == .switchMode
                            || (sink.delivered == 0 && !fieldTyped && sink.streamsBegun == 0)))
            }
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

        func stop() -> (url: URL?, samples: [Float]) {
            isRecording = false
            return (created.last, Self.samples(input))
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

        init(states: [String: ModelState], transcript: String, liveFails: Bool) {
            self.states = states
            self.transcript = transcript
            self.liveFails = liveFails
        }

        func state(_ model: String) -> ModelState { states[model] ?? .ready }
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
            isReady(model) ? transcript : nil
        }
        func transcribe(_ url: URL, model: String) async -> String? {
            await awaitReady(model) ? transcript : nil
        }
        func startLiveDictation(model: String,
                                onUpdate: @escaping @MainActor (String, Float) -> Void,
                                onFailure: (@MainActor () -> Void)?) -> Bool {
            liveStarts += 1
            guard !liveFails else { return false }
            liveUpdate = onUpdate
            return true
        }
        func liveSamplesSnapshot(model: String) -> [Float] { Recorder.samples(.speech) }
        var liveConfirmedText: String { "" }
        var liveConfirmedEndSeconds: Double { 0 }
        func stopLiveDictation() { liveUpdate = nil }
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
