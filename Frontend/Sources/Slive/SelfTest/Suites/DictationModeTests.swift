import AVFoundation
import Foundation

/// The dictation modes: which ones a build registers, how gestures reach
/// them, and each mode's flow on fakes (no mic, no model, no keystrokes).
@MainActor
enum DictationModeTests {
    static let suite = TestSuite(name: "Dictation modes") { t in
        print("[Dictation modes]")
        registry(&t)
        routing(&t)
        dictate(&t)
        assist(&t)
        stream(&t)
    }

    // MARK: - Registry

    private static func registry(_ t: inout Checks) {
        let full = Harness()
        var built = 0
        let fullModes = ModeRegistry.standard(full.ctx, continuous: full.continuous,
                                              assistant: { built += 1; return full.assistant }(),
                                              capabilities: Capabilities(hasServer: true))
        t.equal(fullModes.actions, [.dictate, .assist, .stream], "Full registers dictate, assist and stream")
        t.check(fullModes.mode(for: .dictate) is DictateMode && fullModes.mode(for: .assist) is AssistMode
                && fullModes.mode(for: .stream) is StreamMode, "each action maps to its mode type")
        t.check(HotkeyAction.allCases.allSatisfy { fullModes.mode(for: $0)?.action == $0 },
                "every action has a mode in Full, keyed by its own action")
        t.equal(built, 1, "Full builds the assistant once")

        let lite = Harness()
        built = 0
        let liteModes = ModeRegistry.standard(lite.ctx, continuous: lite.continuous,
                                              assistant: { built += 1; return lite.assistant }(),
                                              capabilities: Capabilities(hasServer: false))
        t.equal(liteModes.actions, [.dictate, .stream], "Lite registers no assistant")
        t.check(liteModes.mode(for: .assist) == nil && built == 0, "Lite never builds the assistant")
        t.check(lite.presenter.model.onContinue == nil && full.presenter.model.onContinue != nil,
                "only a registered assistant wires Continue")
        t.check(liteModes.actions.allSatisfy { $0.spec.isAvailable(in: Capabilities(hasServer: false)) },
                "registered actions are exactly the ones the build can run")
    }

    // MARK: - Routing

    /// Records what the registry asked of it.
    class FakeMode: DictationMode {
        class var action: HotkeyAction { .dictate }
        let log: Trail
        /// Told when capturing starts, as the real modes do.
        weak var session: SessionCoordinator?
        var capturing = false
        var startsCapturing = true
        init(_ log: Trail) { self.log = log }
        func begin() {
            log.add("\(Self.action) begin")
            capturing = startsCapturing
            if capturing { session?.recordingStarted() }
        }
        func end() { log.add("\(Self.action) end"); capturing = false }
        func cancel() { log.add("\(Self.action) cancel"); capturing = false }
        func dismiss() { log.add("\(Self.action) dismiss") }
        var isCapturing: Bool { capturing }
    }
    final class FakeDictate: FakeMode {}
    final class FakeAssist: FakeMode { override class var action: HotkeyAction { .assist } }
    final class FakeStream: FakeMode { override class var action: HotkeyAction { .stream } }

    private static func routing(_ t: inout Checks) {
        func make(_ capabilities: Capabilities) -> (SessionCoordinator, ModeRegistry, Trail, ManualScheduler,
                                                    InFlightWork, FakeDictate) {
            let clock = ManualScheduler()
            let session = SessionCoordinator(scheduler: clock, holdDelay: { 0.15 })
            let work = InFlightWork(queue: DictationQueue(), session: session)
            let registry = ModeRegistry(capabilities: capabilities, work: work)
            let log = Trail()
            let dictate = FakeDictate(log), assist = FakeAssist(log), stream = FakeStream(log)
            for mode in [dictate, assist, stream] as [FakeMode] { mode.session = session }
            registry.register(dictate)
            registry.register(assist)
            registry.register(stream)
            session.handler = registry
            return (session, registry, log, clock, work, dictate)
        }

        do {
            let (s, r, log, clock, _, _) = make(Capabilities(hasServer: true))
            s.keyDown(.stream)
            clock.advance(by: 0.15)
            s.keyUp()
            clock.advance(by: SessionCoordinator.postReleaseCaptureSeconds)
            s.keyDown(.assist)
            clock.advance(by: 0.15)
            s.keyUp()
            clock.advance(by: 1)
            t.equal(log.all, ["stream begin", "stream end", "assist begin", "assist end"],
                    "a hold begins and ends the mode of its own action")
            t.check(!r.isCapturing, "nothing captures after the releases")
        }

        do {
            let (s, r, log, clock, work, _) = make(Capabilities(hasServer: true))
            s.keyDown(.dictate)
            clock.advance(by: 0.15)
            t.check(r.isCapturing && s.isSessionLive, "a capturing mode makes the session live")
            let request = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
            work.request = request
            clock.advance(by: 0.3)
            s.toggleTapped(.stream)   // the second tap of a double, 0.3s into the hold
            t.equal(log.all, ["dictate begin", "dictate cancel", "assist cancel", "stream cancel", "stream begin"],
                    "a false start cancels every mode, in priority order, then the toggle begins")
            t.check(work.request == nil && request.isCancelled, "abort cancels the in-flight request")
            t.equal(s.toggleActive, .stream, "the toggle session is live")
        }

        do {
            let (s, r, log, _, _, dictate) = make(Capabilities(hasServer: true))
            dictate.startsCapturing = false   // mic blocked
            s.toggleTapped(.dictate)
            t.check(s.toggleActive == nil && !r.isCapturing, "a mode that doesn't start leaves no toggle live")
            r.dismissAll()
            t.equal(Array(log.all.suffix(3)), ["dictate dismiss", "assist dismiss", "stream dismiss"],
                    "✕ reaches every mode")
        }

        do {
            let (s, r, log, clock, _, _) = make(Capabilities(hasServer: false))
            s.keyDown(.assist)
            clock.advance(by: 0.15)
            s.keyUp()
            clock.advance(by: 1)
            s.toggleTapped(.assist)
            t.check(log.all.isEmpty && !r.isCapturing && s.toggleActive == nil,
                    "an unregistered action (Lite's assistant) does nothing")
        }
    }

    // MARK: - Dictate

    private static func dictate(_ t: inout Checks) {
        do {
            let h = Harness()
            let mode = DictateMode(h.ctx)
            let wav = h.recorder.arm()
            mode.end()
            h.settle { h.ctx.queue.isEmpty }
            t.equal(h.trail.all, ["typed hello world", "history hello world", "training hello world",
                                  "pace hello world"], "types first, then history, training and stats")
            t.equal(h.speech.decoded, 1, "decoded once, from the in-memory samples")
            t.check(!FileManager.default.fileExists(atPath: wav.path), "the release's WAV is removed")
            t.check(!h.recorder.isRecording && !mode.isCapturing, "the recorder is stopped")
        }

        do {
            let h = Harness()
            h.settings.autoInsert = false
            let mode = DictateMode(h.ctx)
            h.recorder.arm()
            mode.end()
            h.settle { h.ctx.queue.isEmpty }
            t.check(!h.trail.all.contains { $0.hasPrefix("typed") } && h.sink.delivered == 0,
                    "auto-insert off: the typing sink is never asked")
            t.equal(h.presenter.state, .result(OverlayResult(text: "hello world", note: nil)),
                    "auto-insert off: the copy box, without a note")
            t.equal(h.trail.all.first, "history hello world", "auto-insert off: still kept in history")
        }

        do {
            let h = Harness()
            h.sink.verdict = .blocked(note: "Allow Accessibility")
            let mode = DictateMode(h.ctx)
            h.recorder.arm()
            mode.end()
            h.settle { h.ctx.queue.isEmpty }
            t.check(!h.trail.all.contains { $0.hasPrefix("typed") } && h.sink.delivered == 1,
                    "a blocked sink: asked once, nothing typed")
            t.equal(h.presenter.state, .result(OverlayResult(text: "hello world", note: "Allow Accessibility")),
                    "a blocked sink: the copy box says why")
        }

        do {
            let h = Harness()
            let mode = DictateMode(h.ctx)
            h.recorder.arm(silence: true)
            mode.end()
            t.equal(h.presenter.state, .result(OverlayResult(text: "No sound. Check your microphone.")),
                    "digital silence says so")
            t.check(h.ctx.queue.isEmpty && h.speech.decoded == 0, "and never decodes")
        }

        do {
            let h = Harness()
            let mode = DictateMode(h.ctx)
            h.recorder.arm()
            mode.cancel()
            t.check(!h.recorder.isRecording && h.trail.all.isEmpty && h.speech.decoded == 0,
                    "a false start is thrown away")
        }
    }

    // MARK: - Assist

    private static func assist(_ t: inout Checks) {
        let h = Harness()
        var config = h.settings.assistantConfig
        config.attachScreenshot = false
        h.settings.assistantConfig = config
        let mode = AssistMode(h.ctx, assistant: h.assistant, screenshot: { nil })

        h.run { await mode.runAssistant(on: "q1") }
        t.check(h.assistant.histories.count == 1 && h.assistant.histories[0] == nil,
                "a first question sends no history")
        t.equal(h.presenter.state.resultText, "a1", "the answer is shown")
        t.equal(h.trail.all, ["history a1"], "the answer is kept in history")

        h.run { await mode.runAssistant(on: "q2") }
        t.check(h.assistant.histories[1] == nil, "without Continue the next question starts fresh")

        h.presenter.model.onContinue?()   // the Continue button
        t.check(h.presenter.isIdle, "Continue hides the box")
        h.run { await mode.runAssistant(on: "q3") }
        t.equal(h.assistant.histories[2]?.map(\.content), ["q2", "a2"], "Continue sends the last turn")
        h.presenter.model.onContinue?()
        h.run { await mode.runAssistant(on: "q4") }
        t.equal(h.assistant.histories[3]?.count, 4, "continuing again keeps the whole chat")

        h.assistant.fails = true
        h.presenter.model.onContinue?()
        h.run { await mode.runAssistant(on: "q5") }
        h.assistant.fails = false
        h.presenter.model.onContinue?()
        h.run { await mode.runAssistant(on: "q6") }
        t.equal(h.assistant.histories[5]?.count, 6, "a failed answer adds nothing to the chat")

        h.presenter.model.onContinue?()
        mode.dismiss()   // ✕
        h.run { await mode.runAssistant(on: "q7") }
        t.check(h.assistant.histories[6] == nil, "✕ ends the chat")
    }

    // MARK: - Stream

    private static func stream(_ t: inout Checks) {
        do {
            let h = Harness()
            let mode = StreamMode(h.ctx, continuous: h.continuous)
            mode.begin()
            t.equal(h.sink.streamsBegun, 1, "a stream claims the field once (beginStream)")
            t.check(mode.isCapturing && h.presenter.state == .listening(.live), "it streams with the live pill")
            h.speech.liveUpdate?("hello there", 0.5)
            h.settle { h.sink.field == "hello there" }
            t.equal(h.sink.field, "hello there", "the typist types into the claimed handle")
            h.settle { h.trail.all.contains("cue stream") }
            t.check(h.trail.all.contains("cue stream"), "the stream's activation cue plays")
            mode.cancel()
            t.check(!mode.isCapturing && h.speech.liveStopped, "a false start stops the stream")
        }

        do {
            let h = Harness()
            h.sink.verdict = .blocked(note: nil)
            let mode = StreamMode(h.ctx, continuous: h.continuous)
            mode.begin()
            h.speech.liveUpdate?("hello there", 0.5)
            h.settle(0.2) { false }
            t.check(h.sink.field.isEmpty && h.sink.streamsBegun == 1, "a refused handle types nothing")
            mode.dismiss()
            t.check(!mode.isCapturing, "✕ stops the stream")
        }

        do {
            let h = Harness()
            h.speech.ready = []
            let mode = StreamMode(h.ctx, continuous: h.continuous)
            mode.begin()
            t.check(!mode.isCapturing && h.sink.streamsBegun == 0, "no model in memory: nothing streams")
            t.equal(h.presenter.state.resultText, "Loading model. Try again shortly.", "and it says why")
        }
    }

    // MARK: - Fakes

    /// A thread-safe event list (the typist calls the sink off-main).
    final class Trail: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    final class FakeRecorder: Recording {
        var isRecording = false
        private var capture: (url: URL?, samples: [Float]) = (nil, [])

        /// A hold is recording; `stop` returns a WAV file and 1s of speech-loud samples.
        @discardableResult
        func arm(silence: Bool = false) -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("slive-modetest-\(UUID().uuidString).wav")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            let samples = (0..<16_000).map { silence ? 0 : Float(sin(Double($0) * 0.17) * 0.3) }
            capture = (url, samples)
            isRecording = true
            return url
        }

        func start(_ options: CaptureOptions) -> Bool { isRecording = true; return true }

        func stop() -> (url: URL?, samples: [Float]) {
            isRecording = false
            return capture
        }
    }

    final class FakeSpeech: DictationSpeech {
        var ready: Set<String>
        var transcript = "hello world"
        var decoded = 0
        var liveUpdate: (@MainActor (String, Float) -> Void)?
        var liveStopped = false
        init(ready: Set<String>) { self.ready = ready }

        func isReady(_ model: String) -> Bool { ready.contains(model) }
        func canBecomeReady(_ model: String) -> Bool { isReady(model) }
        func status(for model: String) -> ModelStatus { isReady(model) ? .ready : .preparing("Loading") }
        func servingModel(wanted: String, fallback: String?) -> String {
            if isReady(wanted) { return wanted }
            if let fallback, isReady(fallback) { return fallback }
            return wanted
        }
        func select(_ model: String) {}
        func primeIfCold(_ model: String) {}
        func awaitReady(_ model: String) async -> Bool { isReady(model) }
        func transcribeSamples(_ samples: [Float], model: String) async -> String? {
            decoded += 1
            return transcript
        }
        func transcribe(_ url: URL, model: String) async -> String? {
            decoded += 1
            return transcript
        }
        func startLiveDictation(model: String,
                                onUpdate: @escaping @MainActor (String, Float) -> Void,
                                onFailure: (@MainActor () -> Void)?) -> Bool {
            liveUpdate = onUpdate
            liveStopped = false
            return true
        }
        func liveSamplesSnapshot(model: String) -> [Float] { [] }
        var liveConfirmedText: String { "" }
        var liveConfirmedEndSeconds: Double { 0 }
        func stopLiveDictation() { liveStopped = true }
    }

    final class FakeModels: ModelServing {
        var servingDictationModel: String?
        var servingContinuousModel: String?
        func downloadContinuousModelIfNeeded(retryFailed: Bool) -> Bool { false }
    }

    struct FakeRecords: DictationRecords {
        let trail: Trail
        func addToHistory(_ text: String) { trail.add("history \(text)") }
        func addTrainingPair(_ text: String, audioURL: URL) { trail.add("training \(text)") }
        func recordPace(_ text: String, seconds: TimeInterval) { trail.add("pace \(text)") }
    }

    /// A field: types only when its verdict allows.
    final class FakeSink: TextSink, LiveTextSink, @unchecked Sendable {
        private let lock = NSLock()
        private let trail: Trail
        var verdict = Deliverability.ok
        private(set) var delivered = 0
        private(set) var streamsBegun = 0
        private var text = ""
        init(trail: Trail) { self.trail = trail }

        var field: String { lock.lock(); defer { lock.unlock() }; return text }

        func canDeliver() -> Deliverability { verdict }
        func deliver(_ text: String, onDeliveryFailure: @escaping () -> Void) -> Bool {
            delivered += 1
            guard verdict.allowsDelivery else { return false }
            trail.add("typed \(text)")
            return true
        }
        func beginStream() -> LiveStreamHandle {
            streamsBegun += 1
            return LiveStreamHandle(allowed: verdict.allowsDelivery, target: nil)
        }
        func replace(backspaces: Int, insert: String) {
            lock.lock(); defer { lock.unlock() }
            text.removeLast(min(backspaces, text.count))
            text += insert
        }
        func stillOurs(_ handle: LiveStreamHandle) -> Bool { true }
    }

    final class FakeAssistant: AssistantService {
        var histories: [[AssistantClient.HistoryItem]?] = []
        var fails = false
        func ensureHealthy() async -> Bool { true }
        var lastSpawnError: String? { nil }
        func apiKey(for provider: AssistantProvider) -> String { "" }
        func askStream(_ question: String, config: AssistantConfig, apiKey: String,
                       images: [AssistantClient.ImageInput]?,
                       history: [AssistantClient.HistoryItem]?) -> AsyncThrowingStream<String, Error> {
            histories.append(history)
            let answer = "a" + question.dropFirst()
            let fails = self.fails
            return AsyncThrowingStream { continuation in
                if fails { continuation.finish(throwing: URLError(.timedOut)); return }
                continuation.yield(answer)
                continuation.finish()
            }
        }
    }

    /// One mode context on fakes: in-memory settings, a manual clock, the
    /// overlay on a recorded surface.
    @MainActor final class Harness {
        let trail = Trail()
        let settings = Settings(store: InMemoryStore())
        let recorder = FakeRecorder()
        let speech: FakeSpeech
        let sink: FakeSink
        let assistant = FakeAssistant()
        let presenter: OverlayPresenter
        let ctx: ModeContext
        let continuous: ContinuousDictation

        init() {
            settings.continuousTypeCPS = 1000   // instant: no pacing to wait out
            speech = FakeSpeech(ready: [settings.whisperModel, settings.continuousModel])
            sink = FakeSink(trail: trail)
            presenter = OverlayStateTests.make().0
            let clock = ManualScheduler()
            let session = SessionCoordinator(scheduler: clock, holdDelay: { 0 })
            let queue = DictationQueue()
            let trail = self.trail
            ctx = ModeContext(
                recorder: recorder, speech: speech, models: FakeModels(), presenter: presenter,
                queue: queue, session: session, work: InFlightWork(queue: queue, session: session),
                settings: settings, records: FakeRecords(trail: trail), report: FaultSink { _, _, _, _, _, _, _ in },
                typing: sink, typingBlockedNote: { "Allow Accessibility" },
                captureOptions: { CaptureOptions() }, cue: { trail.add("cue \($0)") },
                micAuthorization: { .authorized })
            continuous = ContinuousDictation(speech: speech, sink: sink, settings: settings)
        }

        /// Spin the main run loop until `done` (the mode's tasks run on it).
        func settle(_ seconds: TimeInterval = 5, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
        }

        /// Run `body` on the main actor to completion.
        func run(_ body: @escaping @MainActor () async -> Void) {
            var finished = false
            Task { @MainActor in
                await body()
                finished = true
            }
            settle { finished }
        }
    }
}

private extension OverlayState {
    var resultText: String? {
        if case .result(let r) = self { return r.text }
        return nil
    }
}
