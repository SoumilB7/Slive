import AVFoundation
import Combine
import Foundation
import SliveTestKit

/// G1 live typing ("sim-live"): the real SessionCoordinator → ModeRegistry
/// → StreamMode → ContinuousDictation → LiveTypist → OverlayPresenter, on
/// fakes only at their seams. A seeded user holds, toggles, re-presses during
/// a final pass, ✕es and flips Type at cursor; a seeded world streams live
/// text, finishes final passes in any order (each is a continuation the
/// world resumes), drops the mic and refuses to start it. Time is virtual:
/// one manual clock drives the gesture and overlay timers and every typist's
/// queue (each typist gets a lane the world drains).
///
/// The field holds real text ("Dear team, " first) and applies each
/// keystroke exactly; with the transform profile on it also does smart
/// dashes, auto-closing brackets and a text replacement, as many Mac apps do.
/// Every word a session hears is a token naming its session ("s3w2"), so any
/// text can be traced to who said it.
@MainActor
enum SimLive {
    static let family = GauntletFamily(name: "sim-live", seeded: true) { run in
        SimKit.onMainQueue {
            SimKit.runSeeds(&run, family: "sim-live", salt: 0x11FE_7E57, invariants: invariants,
                            generate: generate, play: play, script: script)
        }
    }

    static let fieldIntegrity = "sim-live.field-integrity"
    static let invariants = [
        SimKit.Invariant(id: fieldIntegrity, name: "pre-existing text untouched; field = it + each session's "
                         + "text, in order (plain field)"),
        SimKit.Invariant(id: "F30", name: "the same with smart dashes, auto-brackets and text replacement"),
        SimKit.Invariant(id: "F6", name: "after a re-press, an older session never types, shows or survives ✕ "
                         + "in the new one's place"),
        SimKit.Invariant(id: "sim-live.one-owner", name: "an older session never changes the pill after a newer one starts"),
        SimKit.Invariant(id: "sim-live.cancel", name: "✕ (or a false start) cancels the session it was meant for"),
        SimKit.Invariant(id: "P-NO-LOSS", name: "every session's final text lands in the field, a copy box or history"),
        SimKit.Invariant(id: "sim-live.quiesce", name: "once the user lets go, no stream stays live"),
    ]

    static let preExisting = "Dear team, "

    // MARK: - Script

    struct Config {
        /// Smart dashes, auto-closing brackets, "omw" → "on my way".
        let transforms: Bool
        let cps: Double
        /// Picks each session's words.
        let wordSeed: UInt64
    }

    enum Decode { case heard, failed, empty }

    enum Event {
        case press, release, tap, dismiss, flipTyping
        case wait(TimeInterval)
        /// The live stream hears one more word; `variant` > 0 garbles the
        /// last one (it's revised by a later pass or the final one).
        case live(variant: Int)
        /// A pass that was in flight when its stream stopped arrives late.
        case stale
        /// Finish a pending final pass (`pick` mod the number pending).
        case resolve(pick: Int, Decode)
        case micLost, micFails, startFails
    }

    static func generate(_ dice: inout SimKit.Dice) -> (Config, [Event]) {
        let config = Config(transforms: dice.chance(35), cps: dice.chance(50) ? 1000 : 40,
                            wordSeed: UInt64(dice.below(1 << 30)))
        var events: [Event] = []
        for _ in 0..<(28 + dice.below(24)) {
            let e: Event = dice.weighted([
                (9, .press), (9, .release), (6, .tap), (5, .dismiss), (3, .flipTyping),
                (15, .wait(dice.pick([0.02, 0.05, 0.12, 0.3, 0.6, 1.2]))),
                (3, .wait(dice.pick([8.5, 9.5]))),
                (22, .live(variant: dice.weighted([(60, 0), (14, 1), (14, 2), (12, 3)]))),
                (3, .stale),
                (12, .resolve(pick: dice.below(4), dice.weighted([(80, Decode.heard), (12, .failed), (8, .empty)]))),
                (2, .micLost), (1, .micFails), (1, .startFails),
            ])
            events.append(e)
        }
        return (config, events)
    }

    /// Session `k`'s words: 2–4 tokens, some with a dash pair, in brackets,
    /// or after "omw" (the field transforms' triggers).
    static func words(_ config: Config, session k: Int) -> [String] {
        var dice = SimKit.Dice(seed: config.wordSeed, salt: UInt64(k) &* 7919)
        var out: [String] = []
        for j in 1...(2 + dice.below(3)) {
            let token = "s\(k)w\(j)"
            switch dice.weighted([(55, 0), (18, 1), (15, 2), (12, 3)]) {
            case 1: out.append(token + "--")
            case 2: out.append("(\(token))")
            case 3: out += ["omw", token]
            default: out.append(token)
            }
        }
        return out
    }

    /// A live pass's garbled last word, as a recogniser's first guess.
    static func garble(_ word: String, _ variant: Int) -> String {
        switch variant {
        case 1: return word + "--"
        case 2: return "(" + word
        case 3: return String(word.dropLast())
        default: return word
        }
    }

    static func label(_ e: Event) -> String {
        switch e {
        case .press: return "press stream key"
        case .release: return "release stream key"
        case .tap: return "tap stream toggle"
        case .dismiss: return "✕"
        case .flipTyping: return "flip Type at cursor"
        case .wait(let s): return String(format: "wait %.2fs", s)
        case .live(let v): return v == 0 ? "live pass" : "live pass (garbled \(v))"
        case .stale: return "late pass from a stopped stream"
        case .resolve(let p, let d): return "final pass #\(p) finishes: \(d)"
        case .micLost: return "mic lost"
        case .micFails: return "mic fails"
        case .startFails: return "next mic start fails"
        }
    }

    static func describe(_ state: OverlayState) -> String {
        switch state {
        case .idle: return "hidden"
        case .listening: return "the listening pill"
        case .transcribing: return "the transcribing pill"
        case .result(let r): return "a box «\(r.text)»"
        }
    }

    static func script(_ config: Config, _ events: [Event]) -> String {
        let world = World(config)
        var lines = ["    transforms \(config.transforms ? "on" : "off"), \(Int(config.cps)) cps"]
        for e in events {
            lines.append("    \(SimKit.stamp(world.now)) \(label(e))")
            world.apply(e)
        }
        world.quiesce()
        lines.append("    → field «\(world.field.string)»")
        lines.append("    → history \(world.records.history)")
        world.tearDown()
        return lines.joined(separator: "\n")
    }

    static func play(_ config: Config, _ events: [Event]) -> SimKit.Findings {
        let world = World(config)
        for e in events { world.apply(e) }
        world.quiesce()
        let found = world.evaluate()
        world.tearDown()
        return found
    }

    // MARK: - The field

    /// Text plus a caret, typed into the way an app does it. With
    /// `transforms` the app rewrites what it's sent, so what lands differs
    /// from what the typist believes it typed.
    struct FieldText {
        private(set) var chars: [Character]
        private(set) var caret: Int
        let transforms: Bool

        init(_ text: String, transforms: Bool) {
            chars = Array(text)
            caret = chars.count
            self.transforms = transforms
        }

        var string: String { String(chars) }

        /// Returns the character it took from before the caret.
        @discardableResult
        mutating func backspace() -> Character? {
            guard caret > 0 else { return nil }
            if transforms, chars[caret - 1] == "(", caret < chars.count, chars[caret] == ")" {
                chars.remove(at: caret)   // deleting an auto-closed pair takes both
            }
            caret -= 1
            return chars.remove(at: caret)
        }

        mutating func type(_ c: Character) {
            if transforms {
                if c == "-", caret > 0, chars[caret - 1] == "-" { chars[caret - 1] = "—"; return }
                if c == "(" { chars.insert(contentsOf: ["(", ")"], at: caret); caret += 1; return }
                if c == ")", caret < chars.count, chars[caret] == ")" { caret += 1; return }
                if c == " " { replaceWordBeforeCaret("omw", with: "on my way") }
            }
            chars.insert(c, at: caret)
            caret += 1
        }

        private mutating func replaceWordBeforeCaret(_ word: String, with replacement: String) {
            let w = Array(word)
            let start = caret - w.count
            guard start >= 0, Array(chars[start..<caret]) == w, start == 0 || chars[start - 1] == " " else { return }
            chars.replaceSubrange(start..<caret, with: Array(replacement))
            caret = start + replacement.count
        }

        /// What typing `text` cleanly (no backspaces) after `pre` would leave.
        static func typed(_ text: String, after pre: String, transforms: Bool) -> String {
            var f = FieldText(pre, transforms: transforms)
            for c in text { f.type(c) }
            return f.string
        }
    }

    /// The typists' queues: one lane per typist, run by the world. Plain
    /// (not main-actor) state: the typist calls in as if from its own queue.
    final class Lanes: @unchecked Sendable {
        final class Lane: TypistQueue, @unchecked Sendable {
            let index: Int
            unowned let owner: Lanes
            fileprivate var ready: [@Sendable () -> Void] = []
            fileprivate var delayed: [(due: TimeInterval, seq: Int, item: DispatchWorkItem)] = []

            init(index: Int, owner: Lanes) {
                self.index = index
                self.owner = owner
            }

            func run(_ work: @escaping @Sendable () -> Void) { ready.append(work) }

            func run(after seconds: TimeInterval, _ item: DispatchWorkItem) {
                owner.seq += 1
                delayed.append((owner.now + seconds, owner.seq, item))
            }
        }

        var now: TimeInterval = 0
        fileprivate var seq = 0
        private(set) var lanes: [Lane] = []
        /// The lane whose step is running (whose typist is typing).
        private(set) var running: Int?

        func make() -> Lane {
            let lane = Lane(index: lanes.count, owner: self)
            lanes.append(lane)
            return lane
        }

        var hasReady: Bool { lanes.contains { !$0.ready.isEmpty } }

        var nextDue: TimeInterval? {
            lanes.flatMap { $0.delayed.filter { !$0.item.isCancelled }.map(\.due) }.min()
        }

        /// Timed steps due by `t` join their lane's queue, in time order.
        func release(upTo t: TimeInterval) {
            for lane in lanes {
                let due = lane.delayed.filter { $0.due <= t + 1e-9 }.sorted { ($0.due, $0.seq) < ($1.due, $1.seq) }
                lane.delayed.removeAll { $0.due <= t + 1e-9 }
                for d in due {
                    let item = d.item
                    lane.ready.append { if !item.isCancelled { item.perform() } }
                }
            }
        }

        /// Run every ready step, one per lane per round. True if any ran.
        @discardableResult
        func drain() -> Bool {
            var any = false
            var progressed = true
            while progressed {
                progressed = false
                for lane in lanes where !lane.ready.isEmpty {
                    let work = lane.ready.removeFirst()
                    running = lane.index
                    work()
                    running = nil
                    progressed = true
                    any = true
                }
            }
            return any
        }
    }

    /// The focused field. Records which lane sent each edit.
    final class Field: TextSink, LiveTextSink, @unchecked Sendable {
        private let lanes: Lanes
        private(set) var text: FieldText
        /// `removed`: what the backspaces took from before the caret, in field order.
        private(set) var edits: [(lane: Int?, backspaces: Int, insert: String, removed: String)] = []

        init(_ pre: String, transforms: Bool, lanes: Lanes) {
            text = FieldText(pre, transforms: transforms)
            self.lanes = lanes
        }

        var string: String { text.string }

        func canDeliver() -> Deliverability { .ok }
        /// Streams never deliver whole texts (only a dictation would).
        func deliver(_ text: String, onDeliveryFailure: @escaping () -> Void) -> Bool { false }
        func beginStream() -> LiveStreamHandle { LiveStreamHandle(allowed: true, target: nil) }
        func stillOurs(_ handle: LiveStreamHandle) -> Bool { true }
        /// Readable, like a native text view: what's left of the caret.
        func textBeforeCaret(_ count: Int, in handle: LiveStreamHandle) -> String? {
            String(text.chars[max(0, text.caret - count)..<text.caret])
        }

        func replace(backspaces: Int, insert: String) {
            var removed = ""
            for _ in 0..<backspaces { if let c = text.backspace() { removed.insert(c, at: removed.startIndex) } }
            edits.append((lanes.running, backspaces, insert, removed))
            for c in insert { text.type(c) }
        }
    }

    @MainActor final class Records: DictationRecords {
        private(set) var history: [String] = []
        func addToHistory(_ text: String) { history.append(text) }
        func addTrainingPair(_ text: String, audioURL: URL) {}
        func recordPace(_ text: String, seconds: TimeInterval) {}
    }

    /// Passes the coordinator's calls on, noting a false-start abort.
    @MainActor final class Handler: SessionHandler {
        let registry: ModeRegistry
        var onAbort: () -> Void = {}
        init(_ registry: ModeRegistry) { self.registry = registry }
        func beginSession(_ action: HotkeyAction) { registry.beginSession(action) }
        func endSession(_ action: HotkeyAction) { registry.endSession(action) }
        func abortSession() { onAbort(); registry.abortSession() }
        var isCapturing: Bool { registry.isCapturing }
    }

    /// On-device speech, played by the world: live streams it feeds, final
    /// passes it holds until a `resolve`.
    @MainActor final class Speech: DictationSpeech {
        weak var world: World?
        let models: Set<String>
        init(models: Set<String>) { self.models = models }

        func isReady(_ model: String) -> Bool { models.contains(model) }
        func canBecomeReady(_ model: String) -> Bool { isReady(model) }
        func status(for model: String) -> ModelStatus { isReady(model) ? .ready : .preparing("Loading") }
        func servingModel(wanted: String, fallback: String?) -> String { wanted }
        func select(_ model: String) {}
        func primeIfCold(_ model: String) {}
        func awaitReady(_ model: String) async -> Bool { isReady(model) }
        func transcribe(_ url: URL, model: String) async -> String? { nil }
        func transcribeSamples(_ samples: [Float], model: String) async -> String? {
            guard let world else { return nil }
            return await withCheckedContinuation { world.finalPassStarted($0) }
        }
        func startLiveDictation(model: String, onUpdate: @escaping @MainActor (String, Float) -> Void,
                                onFailure: (@MainActor () -> Void)?,
                                onMicLost: (@MainActor () -> Void)?) -> Bool {
            world?.streamStarted(Stream(update: onUpdate, failure: onFailure, micLost: onMicLost)) ?? false
        }
        func liveSamplesSnapshot(model: String) -> [Float] { world?.stopBegan(); return [] }
        var liveConfirmedText: String { "" }
        var liveConfirmedEndSeconds: Double { 0 }
        func stopLiveDictation() { world?.streamStopped() }
    }

    struct Stream {
        let update: @MainActor (String, Float) -> Void
        let failure: (@MainActor () -> Void)?
        let micLost: (@MainActor () -> Void)?
    }

    /// What really happened to one session, as the world saw it.
    struct Truth {
        enum Phase { case streaming, finalPending, done, failedToStart, dropped }
        let index: Int
        let lane: Int?
        let typeAtCursor: Bool
        let words: [String]
        let editsAtStart: Int
        var phase: Phase
        var heard = 0
        /// Every live text it was sent while streaming.
        var targets: [String] = []
        /// Its last streamed text (the fallback for a failed final pass).
        var lastHeard = ""
        /// The text the session should end with, once its final pass ran.
        var expected: String?
        /// A newer session started before its final pass finished.
        var supersededBy: Int?
        /// Why it was thrown away, and how far the field, history and
        /// boxes had got by then.
        var discard: (why: String, edits: Int, history: Int, boxes: Int)?
    }

    // MARK: - World

    @MainActor final class World {
        let config: Config
        let clock: ManualScheduler
        let lanes: Lanes
        let field: Field
        let settings: Settings
        let records: Records
        let speech: Speech
        let model: AudioModel
        let presenter: OverlayPresenter
        let coordinator: SessionCoordinator
        let work: InFlightWork
        let registry: ModeRegistry
        let handler: Handler
        let continuous: ContinuousDictation
        private let pipeline: DictationPipeline
        private var observer: AnyCancellable?

        private(set) var sessions: [Truth] = []
        private var streams: [Stream] = []
        private var finalPasses: [(session: Int, resume: CheckedContinuation<String?, Never>)] = []
        private var stopping: Int?
        private var holding = false
        private var failNextStart = false
        /// Texts the copy box showed, in order.
        private(set) var boxes: [String] = []
        private var pillChanges = 0
        /// Which session's late work the current step runs, if older than the newest.
        private var oldStep: Int?
        private(set) var ownerViolations: [String] = []
        private(set) var stuckStream = false

        init(_ config: Config) {
            self.config = config
            let clock = ManualScheduler(), lanes = Lanes(), settings = Settings(store: InMemoryStore(), loginItemEnabled: { false })
            let records = Records(), model = AudioModel()
            settings.continuousTypeCPS = config.cps
            let field = Field(SimLive.preExisting, transforms: config.transforms, lanes: lanes)
            let speech = Speech(models: [settings.whisperModel, settings.continuousModel])
            let surface = OverlayStateTests.FakeSurface(model: model)
            let presenter = OverlayPresenter(model: model, scheduler: clock) { surface }
            let coordinator = SessionCoordinator(scheduler: clock, holdDelay: { 0.15 })
            let queue = DictationQueue()
            let work = InFlightWork(queue: queue, session: coordinator)
            let registry = ModeRegistry(capabilities: Capabilities(hasServer: true), work: work)
            let continuous = ContinuousDictation(speech: speech, sink: field, settings: settings,
                                                 makeTypist: { LiveTypist(sink: $0, queue: lanes.make()) })
            let ctx = ModeContext(
                recorder: DictationModeTests.FakeRecorder(), speech: speech, models: DictationModeTests.FakeModels(),
                presenter: presenter, queue: queue, session: coordinator, work: work, settings: settings,
                records: records, report: FaultSink { _, _, _, _, _, _, _ in }, typing: field,
                typingBlockedNote: { "Allow Accessibility" }, captureOptions: { CaptureOptions() },
                cue: { _ in }, micAuthorization: { .authorized },
                secureInputNotice: { nil }, wakeFrontApp: {})
            registry.register(StreamMode(ctx, continuous: continuous))
            let handler = Handler(registry)
            coordinator.handler = handler
            (self.clock, self.lanes, self.settings, self.records, self.model) = (clock, lanes, settings, records, model)
            (self.field, self.speech, self.presenter, self.coordinator) = (field, speech, presenter, coordinator)
            (self.work, self.registry, self.continuous, self.handler) = (work, registry, continuous, handler)
            pipeline = .live(vocabulary: settings.hotwords)
            speech.world = self
            handler.onAbort = { [weak self] in
                guard let self, let k = self.sessions.indices.last, self.sessions[k].phase == .streaming else { return }
                self.discard(k, "a false start")
            }
            // Tag the waveform feed: each session's passes carry its own energy.
            let push = continuous.onEnergy
            continuous.onEnergy = { [weak self] energy in self?.energyPushed(energy); push?(energy) }
            observer = model.$state.sink { [weak self] state in
                guard let self else { return }
                self.pillChanges += 1
                if case .result(let r) = state { self.boxes.append(r.text) }
            }
        }

        var now: TimeInterval { clock.now.timeIntervalSinceReferenceDate }

        // MARK: Speech callbacks

        func streamStarted(_ stream: Stream) -> Bool {
            let k = sessions.count
            let ok = !failNextStart
            failNextStart = false
            for i in sessions.indices where sessions[i].phase == .finalPending && sessions[i].supersededBy == nil {
                sessions[i].supersededBy = k
            }
            // A stream replaced while still live (no stop): nothing will end it.
            if let last = sessions.indices.last, sessions[last].phase == .streaming { sessions[last].phase = .dropped }
            sessions.append(Truth(index: k, lane: lanes.lanes.last?.index, typeAtCursor: settings.autoInsert,
                                  words: SimLive.words(config, session: k), editsAtStart: field.edits.count,
                                  phase: ok ? .streaming : .failedToStart))
            streams.append(stream)
            return ok
        }

        func stopBegan() {
            guard let k = sessions.indices.last, sessions[k].phase == .streaming else { return }
            sessions[k].phase = .finalPending
            stopping = k
        }

        func streamStopped() {
            // A stop with no final pass is a cancel.
            if let k = sessions.indices.last, sessions[k].phase == .streaming { sessions[k].phase = .dropped }
        }

        func finalPassStarted(_ resume: CheckedContinuation<String?, Never>) {
            finalPasses.append((stopping ?? -1, resume))
            stopping = nil
        }

        private func energyPushed(_ energy: Float) {
            let k = Int((energy * 1024).rounded()) - 1
            if let newest = sessions.indices.last, k < newest {
                ownerViolations.append("session \(k)'s late pass moved session \(newest)'s waveform")
            }
        }

        private func energy(_ k: Int) -> Float { Float(k + 1) / 1024 }

        private func discard(_ k: Int, _ why: String) {
            guard sessions[k].discard == nil else { return }
            sessions[k].discard = (why, field.edits.count, records.history.count, boxes.count)
        }

        /// The text a live pass for session `k` carries.
        private func liveText(_ k: Int, variant: Int) -> String {
            let s = sessions[k]
            var heard = Array(s.words.prefix(s.heard))
            if variant > 0, let last = heard.popLast() { heard.append(SimLive.garble(last, variant)) }
            return heard.joined(separator: " ")
        }

        // MARK: Events

        func apply(_ e: Event) {
            let before = pillChanges
            switch e {
            case .press:
                guard !holding else { return }
                holding = true
                coordinator.keyDown(.stream)
            case .release:
                guard holding else { return }
                holding = false
                coordinator.keyUp()
            case .tap:
                coordinator.toggleTapped(.stream)
            case .dismiss:
                // Only a box or a stuck pill has a ✕ (the live pill is click-through).
                guard presenter.state.isInteractive else { return }
                if let k = sessions.indices.last, [.streaming, .finalPending].contains(sessions[k].phase) {
                    discard(k, "✕")
                }
                work.cancelRequest()   // AppDelegate.dismissOverlay
                coordinator.endToggle()
                registry.dismissAll()
                presenter.dismiss()
            case .flipTyping:
                settings.autoInsert.toggle()
            case .wait(let s):
                advance(s)
                return
            case .live(let variant):
                guard let k = sessions.indices.last, sessions[k].phase == .streaming else { return }
                sessions[k].heard = min(sessions[k].heard + 1, sessions[k].words.count)
                let text = liveText(k, variant: variant)
                sessions[k].targets.append(pipeline.finish(text))
                sessions[k].lastHeard = pipeline.finish(text)
                streams[k].update(text, energy(k))
            case .stale:
                guard let k = sessions.indices.last(where: { sessions[$0].phase != .streaming
                                                             && sessions[$0].phase != .failedToStart }) else { return }
                let s = sessions[k]
                let text = (s.words.prefix(s.heard + 1)).joined(separator: " ")
                oldStep = k < sessions.count - 1 ? k : nil
                streams[k].update(text, energy(k))
            case .resolve(let pick, let kind):
                guard !finalPasses.isEmpty else { return }
                let pass = finalPasses.remove(at: pick % finalPasses.count)
                let k = pass.session
                var reply: String?
                if sessions.indices.contains(k) {
                    switch kind {
                    case .heard: reply = sessions[k].words.joined(separator: " ")
                    case .failed: reply = nil
                    case .empty: reply = ""
                    }
                    sessions[k].phase = .done
                    var final = reply.map(pipeline.clean)
                    if final?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { final = nil }
                    sessions[k].expected = (final.map(pipeline.correct) ?? sessions[k].lastHeard)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    oldStep = k < sessions.count - 1 ? k : nil
                }
                pass.resume.resume(returning: reply)
            case .micLost:
                guard let k = sessions.indices.last, sessions[k].phase == .streaming else { return }
                streams[k].micLost?()
            case .micFails:
                guard let k = sessions.indices.last, sessions[k].phase == .streaming else { return }
                discard(k, "the mic failing")
                streams[k].failure?()
            case .startFails:
                failNextStart = true
            }
            settle()
            if let k = oldStep, pillChanges != before {
                ownerViolations.append("session \(k)'s late work changed the pill after session \(sessions.count - 1) "
                                       + "started (now \(SimLive.describe(presenter.state)))")
            }
            oldStep = nil
        }

        // MARK: Time

        /// Run whatever is runnable now: typist steps and main-actor work,
        /// until three rounds in a row find nothing for the typists (a
        /// resumed task may hop to the main queue once more before it types).
        func settle() {
            var quiet = 0
            for _ in 0..<10_000 {
                let typed = lanes.drain()
                World.drainMainQueue()
                quiet = typed || lanes.hasReady ? 0 : quiet + 1
                if quiet >= 3 { return }
            }
        }

        /// Run every main-queue job queued so far (main-actor tasks resume
        /// there): FIFO, so once a marker queued now has run, so have they.
        static func drainMainQueue() {
            let target = markers + 1
            DispatchQueue.main.async { MainActor.assumeIsolated { World.markers += 1 } }
            while markers < target { _ = CFRunLoopRunInMode(.defaultMode, 0, true) }
        }
        private static var markers = 0

        /// Move virtual time on, stopping at every timer and typist step due.
        func advance(_ seconds: TimeInterval) {
            let end = now + seconds
            for _ in 0..<100_000 {
                let next = [clock.nextDue?.timeIntervalSinceReferenceDate, lanes.nextDue].compactMap { $0 }.min()
                guard let due = next, due <= end else { break }
                clock.advance(by: max(0, due - now))
                lanes.now = max(due, lanes.now)
                lanes.release(upTo: lanes.now)
                settle()
            }
            clock.advance(by: max(0, end - now))
            lanes.now = end
            lanes.release(upTo: end)
            settle()
        }

        /// The user lets go and every final pass finishes.
        func quiesce() {
            if holding { holding = false; coordinator.keyUp() }
            advance(0.5)
            if coordinator.toggleActive != nil { coordinator.toggleTapped(.stream); advance(0.5) }
            if continuous.isActive {
                stuckStream = true
                registry.endSession(.stream)
                advance(0.5)
            }
            while !finalPasses.isEmpty {
                apply(.resolve(pick: 0, .heard))
                advance(0.5)
            }
            advance(20)
        }

        func tearDown() {
            observer = nil
            model.reset()   // stops the waveform timer
        }

        // MARK: Verdicts

        /// Which sessions' tokens a text mentions ("s3w2" → 3).
        static func mentions(_ text: String) -> Set<Int> {
            Set(tokens(text).map(\.session))
        }

        /// With transforms the app rewrites what a session typed; it then stops
        /// correcting and types only new words. That's fine when the field
        /// holds its words once each, in spoken order (the plain field, which
        /// never rewrites, still demands exact text).
        private func appendedInOrder(_ k: Int, _ shadow: String) -> Bool {
            guard config.transforms else { return false }
            let found = SimLive.World.tokens(shadow)
            let words = found.map(\.word)
            return found.allSatisfy { $0.session == k } && zip(words, words.dropFirst()).allSatisfy { $0 < $1 }
        }

        /// Every token in `text`, in order ("s3w2" → session 3, word 2).
        static func tokens(_ text: String) -> [(session: Int, word: Int)] {
            var found: [(session: Int, word: Int)] = []
            let chars = Array(text)
            var i = 0
            while i < chars.count {
                if chars[i] == "s", i == 0 || !chars[i - 1].isLetter {
                    var j = i + 1
                    var digits = ""
                    while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
                    if !digits.isEmpty, j + 1 < chars.count, chars[j] == "w", chars[j + 1].isNumber, let k = Int(digits) {
                        var w = ""
                        j += 1
                        while j < chars.count, chars[j].isNumber { w.append(chars[j]); j += 1 }
                        found.append((k, Int(w) ?? 0))
                    }
                }
                i += 1
            }
            return found
        }

        func evaluate() -> SimKit.Findings {
            var found = SimKit.Findings()
            var fieldProblems: [String] = []
            var f6: [String] = []
            /// Backspaces that took characters other than the ones meant.
            var wrongDeletes: [String] = []
            let sessionOfLane = Dictionary(sessions.compactMap { s in s.lane.map { ($0, s.index) } },
                                           uniquingKeysWith: { first, _ in first })

            // What each session's typist believes it typed (its own region).
            var shadows = Array(repeating: "", count: sessions.count)
            for (n, edit) in field.edits.enumerated() {
                guard let lane = edit.lane, let k = sessionOfLane[lane] else {
                    fieldProblems.append("an edit from no session's typist (-\(edit.backspaces)+\(edit.insert))")
                    continue
                }
                if edit.backspaces > shadows[k].count {
                    fieldProblems.append("session \(k) backspaced \(edit.backspaces) over its \(shadows[k].count) characters")
                }
                let meant = String(shadows[k].suffix(edit.backspaces))
                if edit.removed != meant {
                    wrongDeletes.append("session \(k)'s backspaces took «\(edit.removed)», not its «\(meant)»")
                }
                shadows[k].removeLast(min(edit.backspaces, shadows[k].count))
                shadows[k] += edit.insert
                if let newer = sessions.first(where: { $0.index > k && $0.editsAtStart <= n }) {
                    f6.append("session \(k) typed «\(edit.insert)» (-\(edit.backspaces)) after session \(newer.index) started")
                }
            }

            let real = field.string
            if !real.hasPrefix(preExisting) { fieldProblems.append("pre-existing text altered: «\(real)»") }
            let typed = shadows.joined()
            let want = config.transforms
                ? FieldText.typed(typed, after: preExisting, transforms: true)
                : preExisting + typed
            fieldProblems += wrongDeletes
            // With transforms, typing the net text cleanly isn't the only right
            // field: a retyped ")" can step over an older auto-closed one. If
            // every backspace took exactly what it meant to, nothing was eaten.
            if real != want, !(config.transforms && wrongDeletes.isEmpty) {
                fieldProblems.append("field «\(real)», expected «\(want)»")
            }

            for s in sessions {
                let shadow = shadows[s.index]
                // Cut short (✕, a false start, a newer session): what it had
                // streamed so far, or all of it.
                let partial = shadow.isEmpty || s.targets.contains { $0.hasPrefix(shadow) } || shadow == s.expected
                    || appendedInOrder(s.index, shadow)
                var why: String?
                if s.phase == .failedToStart || !s.typeAtCursor {
                    if !shadow.isEmpty { why = s.typeAtCursor ? "never started" : "had Type at cursor off" }
                } else if let d = s.discard {
                    if !partial { why = "was cancelled by \(d.why)" }
                } else if let newer = s.supersededBy {
                    if !partial { why = "gave way to session \(newer)" }
                } else if s.phase == .dropped {
                    if !partial { why = "was dropped" }
                } else if let expected = s.expected, shadow != expected,
                          // Not typed exactly: its final text must be in a copy box.
                          !(appendedInOrder(s.index, shadow) && boxes.contains(expected)) {
                    why = "finished"
                }
                if let why {
                    fieldProblems.append("session \(s.index) \(why) but typed «\(shadow)» (heard «\(s.expected ?? s.lastHeard)»)")
                }
                for other in SimLive.World.mentions(shadow) where other != s.index {
                    f6.append("session \(s.index) typed session \(other)'s words: «\(shadow)»")
                }
            }
            found.expect(fieldProblems.isEmpty, config.transforms ? "F30" : SimLive.fieldIntegrity,
                         fieldProblems.prefix(3).joined(separator: "; "))

            // Ownership of the pill.
            if sessions.count >= 2 {
                found.expect(ownerViolations.isEmpty, "sim-live.one-owner", ownerViolations.prefix(3).joined(separator: "; "))
                f6 += ownerViolations
            }

            // ✕ and false starts.
            var cancelProblems: [String] = []
            for s in sessions {
                guard let d = s.discard else { continue }
                let lateEdits = field.edits.dropFirst(d.edits).filter { $0.lane == s.lane && s.lane != nil }
                let lateHistory = records.history.dropFirst(d.history).filter { SimLive.World.mentions($0).contains(s.index) }
                let lateBoxes = boxes.dropFirst(d.boxes).filter { SimLive.World.mentions($0).contains(s.index) }
                var what: [String] = []
                if !lateEdits.isEmpty { what.append("typed \(lateEdits.map { "«\($0.insert)»" })") }
                if !lateHistory.isEmpty { what.append("recorded \(lateHistory)") }
                if !lateBoxes.isEmpty { what.append("showed \(lateBoxes)") }
                guard !what.isEmpty else { continue }
                let line = "session \(s.index) \(what.joined(separator: ", ")) after \(d.why)"
                cancelProblems.append(line)
                if sessions.count > s.index + 1 { f6.append(line) }
            }
            if sessions.contains(where: { $0.discard != nil }) {
                found.expect(cancelProblems.isEmpty, "sim-live.cancel", cancelProblems.prefix(3).joined(separator: "; "))
            }

            // Nothing heard is lost.
            var lost: [String] = []
            var judgedLoss = false
            for s in sessions where s.discard == nil && s.phase != .failedToStart {
                let text = s.expected ?? s.lastHeard
                guard !text.isEmpty else { continue }
                judgedLoss = true
                let typedIt = s.typeAtCursor && s.supersededBy == nil && shadows[s.index] == text
                if !(typedIt || records.history.contains(text) || boxes.contains(text)) {
                    lost.append("session \(s.index)'s «\(text)» is nowhere")
                }
            }
            if judgedLoss { found.expect(lost.isEmpty, "P-NO-LOSS", lost.prefix(3).joined(separator: "; ")) }

            // A history entry mixing two sessions' words.
            for entry in records.history where SimLive.World.mentions(entry).count > 1 {
                f6.append("history mixes sessions: «\(entry)»")
            }
            if sessions.count >= 2 { found.expect(f6.isEmpty, "F6", f6.prefix(3).joined(separator: "; ")) }
            found.expect(!stuckStream, "sim-live.quiesce", "a stream was still live after the user let go")
            return found
        }
    }
}
