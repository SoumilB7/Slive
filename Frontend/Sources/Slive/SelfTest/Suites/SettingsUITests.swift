import Foundation
import SliveTestKit

/// The settings window's seams: the page registry, the General card list,
/// permission counts, the window-width parse, and the two view models
/// (ground-truth prompt save rule, training job poll rules) against fakes.
@MainActor
enum SettingsUITests {
    static let suite = TestSuite(name: "Settings UI") { t in
        print("[Settings UI]")
        registry(&t)
        generalCards(&t)
        permissions(&t)
        windowState(&t)
        groundTruthPrompt(&t)
        trainingJob(&t)
    }

    // MARK: - Registry

    private static func registry(_ t: inout Checks) {
        let full = Capabilities(hasServer: true)
        let lite = Capabilities(hasServer: false)
        let all = SettingsRegistry.all

        t.equal(Set(all.map(\.id)).count, all.count, "registry: page ids unique")
        t.equal(Set(all.map(\.title)).count, all.count, "registry: page titles unique")
        t.check(all.allSatisfy { !$0.icon.isEmpty && !$0.title.isEmpty }, "registry: every page has an icon and title")
        t.check(all.allSatisfy { SettingsSection.allCases.contains($0.section) }, "registry: every page has a section")
        t.check(SettingsSection.allCases.allSatisfy { !SettingsRegistry.pages(in: $0, for: full).isEmpty },
                "registry: Full fills every section")

        t.equal(SettingsRegistry.pages(for: full).map(\.title),
                ["General", "Permissions", "Live typing", "Ask", "Vocabulary", "History",
                 "Providers", "Data", "Training"],
                "registry: Full pages in sidebar order")
        t.equal(SettingsRegistry.sections(for: full), [.app, .modes, .library, .lab],
                "registry: Full sections")
        t.equal(SettingsRegistry.pages(for: lite).map(\.id),
                [.general, .permissions, .liveTyping, .vocabulary, .history],
                "registry: Lite hides Ask, Providers, Data, Training")
        t.equal(SettingsRegistry.sections(for: lite), [.app, .modes, .library],
                "registry: Lite has no Lab")
        t.equal(SettingsRegistry.spec(.training, for: lite).id, .general,
                "registry: a page Lite lacks falls back to General")
        t.equal(SettingsRegistry.spec(.data, for: full).id, .data, "registry: lookup by id")

        // Column caps per tier — the values the old per-page switch returned.
        let inf = CGFloat.infinity
        let expected: [SettingsPageID: [CGFloat]] = [
            .general: [inf, 580, 880],
            .permissions: [inf, 580, 580],
            .liveTyping: [inf, 580, 580],
            .assistant: [inf, 580, 580],
            .vocabulary: [inf, 580, 580],
            .history: [inf, 680, 680],
            .providers: [inf, 680, 680],
            .data: [inf, 760, 980],
            .training: [inf, 760, 980],
        ]
        for spec in all {
            let caps = [SliveLayout.compact, .regular, .wide].map { spec.width.cap(for: $0) }
            t.equal(caps, expected[spec.id] ?? [], "registry: \(spec.title) width caps")
        }
    }

    // MARK: - General cards

    private static func generalCards(_ t: inout Checks) {
        t.equal(GeneralCard.allCases,
                [.keys, .liveTyping, .model, .microphone, .behavior, .overlay, .speed],
                "general: narrow order")
        t.equal(GeneralCard.cards(in: .left), [.keys, .liveTyping, .behavior], "general: wide left column")
        t.equal(GeneralCard.cards(in: .right), [.model, .microphone, .overlay], "general: wide right column")
        t.equal(GeneralCard.cards(in: .full), [.speed], "general: speed spans the grid")
    }

    // MARK: - Permissions

    private static func permissions(_ t: inout Checks) {
        var tapWorks = false
        let p = PermissionsModel(hotkeyActive: { tapWorks })
        t.equal(p.grantedCount, 0, "permissions: none granted")
        t.check(p.needsAttention, "permissions: missing ones need attention")
        p.micGranted = true
        p.accessibilityGranted = true
        t.equal(p.grantedCount, 2, "permissions: two of three")
        t.check(p.needsAttention, "permissions: two of three still needs attention")
        tapWorks = true
        t.equal(p.grantedCount, PermissionsModel.required, "permissions: a working tap counts as Input Monitoring")
        t.check(!p.needsAttention, "permissions: all granted, no dot")
        tapWorks = false
        p.inputMonitoringGranted = true
        t.check(p.inputMonitoringWorks && !p.needsAttention, "permissions: granted Input Monitoring counts")
    }

    // MARK: - Window state

    private static func windowState(_ t: inout Checks) {
        let fallback = SliveTheme.windowDefault.width
        t.equal(SettingsWindowState.width(fromAutosavedFrame: "10 20 900 700 0 0 1440 875 "), 900,
                "window: width is the third token")
        t.equal(SettingsWindowState.width(fromAutosavedFrame: nil), fallback, "window: no frame → default")
        t.equal(SettingsWindowState.width(fromAutosavedFrame: "10 20"), fallback, "window: short frame → default")
        t.equal(SettingsWindowState.width(fromAutosavedFrame: "1 2 x 4"), fallback, "window: junk width → default")
        t.equal(SettingsWindowState.width(fromAutosavedFrame: "1 2 0 4"), fallback, "window: zero width → default")
        t.equal(SettingsWindowState.autosaveName, "SliveSettings", "window: autosave name unchanged")
    }

    // MARK: - Ground-truth prompt

    private final class FakePromptClient: GroundTruthPromptClient {
        var calls = 0
        let prompt: String?
        init(_ prompt: String?) { self.prompt = prompt }
        func defaultPrompt() async throws -> String {
            calls += 1
            guard let prompt else { throw SliveError.serverDown(nil) }
            return prompt
        }
    }

    private static func groundTruthPrompt(_ t: inout Checks) {
        let settings = Settings(store: InMemoryStore())
        let client = FakePromptClient("Transcribe exactly.")
        let model = GroundTruthPromptModel(settings: settings, client: client)

        model.load()
        t.equal(model.note, "Loading…", "prompt: loading note while the default is fetched")
        t.check(spin { model.defaultPrompt != nil }, "prompt: default fetched")
        t.equal(model.draft, "Transcribe exactly.", "prompt: empty draft starts at the default")
        t.equal(model.note, nil, "prompt: loading note cleared")

        settings.groundTruthPrompt = "stale"
        model.draft = "  Transcribe exactly.\n"
        model.save()
        t.equal(settings.groundTruthPrompt, "", "prompt: saving the default stores empty (server improvements flow)")
        t.equal(model.note, nil, "prompt: no 'Saved' for the default")

        model.draft = "  Mine, verbatim. "
        model.save()
        t.equal(settings.groundTruthPrompt, "Mine, verbatim.", "prompt: a custom base is stored trimmed")
        t.equal(model.note, "Saved", "prompt: custom save says Saved")

        model.draft = " \n "
        model.save()
        t.equal(settings.groundTruthPrompt, "", "prompt: a blank draft stores empty")

        settings.groundTruthPrompt = "Mine"
        model.reset()
        t.equal(settings.groundTruthPrompt, "", "prompt: reset clears the custom base")
        t.equal(model.draft, "Transcribe exactly.", "prompt: reset shows the default")
        t.equal(client.calls, 1, "prompt: the default is fetched once")

        settings.groundTruthPrompt = "Saved custom"
        let other = GroundTruthPromptModel(settings: settings, client: client)
        other.load()
        t.equal(other.draft, "Saved custom", "prompt: a saved custom base loads without a fetch")
        t.equal(client.calls, 1, "prompt: no fetch for a saved custom base")

        let down = GroundTruthPromptModel(settings: Settings(store: InMemoryStore()), client: FakePromptClient(nil))
        down.load()
        t.check(spin { down.note != "Loading…" }, "prompt: a failed fetch settles")
        t.equal(down.note, "Couldn't load default.", "prompt: a failed fetch says so")
    }

    // MARK: - Training job

    /// Scripted training routes: `statuses` are consumed one poll at a time
    /// (nil = the poll throws); the last entry repeats.
    private final class FakeTrainingClient: TrainingJobClient {
        var statuses: [WhisperTrainingJob?] = []
        var latestJob: WhisperTrainingJob?
        var startError: Error?
        var statusCalls = 0
        var readinessCalls = 0

        func readiness() async throws -> TrainingReadiness {
            readinessCalls += 1
            return try decode(#"{"eligible_count": 60, "required_samples": 50, "remaining_samples": 0, "ready": true, "eligible_audio_minutes": 12.5}"#)
        }
        func latest() async throws -> WhisperTrainingJob? { latestJob }
        func models() async throws -> [WhisperTrainingModel] {
            try decode(#"[{"id": "small", "label": "Small", "hf_model": "openai/whisper-small", "family": "small", "multilingual": true, "detail": ""}]"#)
        }
        func start(sourceModel: String, method: String, name: String?,
                   maxRamGB: Double) async throws -> WhisperTrainingJob {
            if let startError { throw startError }
            return SettingsUITests.job("running")
        }
        func resume(id: String) async throws -> WhisperTrainingJob { SettingsUITests.job("running") }
        func status(id: String) async throws -> WhisperTrainingJob {
            let index = min(statusCalls, statuses.count - 1)
            statusCalls += 1
            guard let job = statuses[index] else { throw SliveError.serverDown(nil) }
            return job
        }
    }

    /// A clock that records each sleep and returns at once (honouring
    /// cancellation like `Task.sleep`).
    private final class FakeClock {
        var sleeps: [UInt64] = []
        func sleep(_ nanoseconds: UInt64) async throws {
            sleeps.append(nanoseconds)
            await Task.yield()
            try Task.checkCancellation()
        }
    }

    nonisolated private static func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    nonisolated fileprivate static func job(_ state: String, error: String? = nil) -> WhisperTrainingJob {
        let errorField = error.map { #", "error": "\#($0)""# } ?? ""
        return try! decode(#"{"id": "job1", "model_name": "small-ft", "state": "\#(state)", "stage": "training", "message": "", "progress": 0.5, "eligible_samples": 60, "required_samples": 50\#(errorField)}"#)
    }

    private static func trainingJob(_ t: inout Checks) {
        let two = TrainingJobModel.pollInterval, three = TrainingJobModel.retryInterval
        t.equal(two, 2_000_000_000, "training: polls every 2 s")
        t.equal(three, 3_000_000_000, "training: retries after 3 s")

        // Four blips, then progress, then done: live updates survive the
        // blips, and finishing refreshes the installed models + readiness.
        do {
            let client = FakeTrainingClient()
            client.statuses = [nil, nil, nil, nil, job("running"), job("done")]
            let clock = FakeClock()
            var modelsChanged = 0
            let model = TrainingJobModel(client: client, onModelsChanged: { modelsChanged += 1 },
                                         sleep: clock.sleep)
            model.start()
            t.check(spin { model.job?.state == "done" }, "training: poll reaches done through 4 failures")
            t.equal(clock.sleeps, [three, three, three, three, two], "training: 3 s after a failure, 2 s while running")
            t.equal(modelsChanged, 1, "training: done refreshes custom models once")
            t.check(spin { client.readinessCalls == 1 }, "training: done re-reads readiness")
            t.equal(model.jobError, nil, "training: recovered blips leave no error")
        }

        // Five failures in a row end live updates with the last error.
        do {
            let client = FakeTrainingClient()
            client.statuses = [nil]
            let clock = FakeClock()
            let model = TrainingJobModel(client: client, onModelsChanged: {}, sleep: clock.sleep)
            model.start()
            t.check(spin { model.jobError != nil }, "training: 5 failed polls surface an error")
            t.equal(client.statusCalls, TrainingJobModel.maxPollFailures, "training: gives up after 5 polls")
            t.equal(clock.sleeps, [three, three, three, three], "training: no sleep after the last failure")
        }

        // A failed job reports its own error.
        do {
            let client = FakeTrainingClient()
            client.statuses = [job("error", error: "Conversion failed")]
            let model = TrainingJobModel(client: client, onModelsChanged: {}, sleep: FakeClock().sleep)
            model.start()
            t.check(spin { model.jobError == "Conversion failed" }, "training: a failed job shows its error")
        }

        // A refused start keeps its message through the follow-up refresh
        // (Oct 29: the refusal never drew).
        do {
            let client = FakeTrainingClient()
            client.startError = SliveError.server(status: 409, message: "Already training")
            client.latestJob = job("error", error: "old failure")
            let model = TrainingJobModel(client: client, onModelsChanged: {}, sleep: FakeClock().sleep)
            model.start()
            t.check(spin { model.readiness != nil && !model.checking }, "training: refused start refreshes")
            t.equal(model.jobError, SliveError.server(status: 409, message: "Already training").localizedDescription,
                    "training: keepingError — the refusal isn't replaced by the old job's error")
        }

        // A plain refresh shows a failed latest job's error; a done one
        // refreshes the installed models.
        do {
            let client = FakeTrainingClient()
            client.latestJob = job("error", error: "old failure")
            let model = TrainingJobModel(client: client, onModelsChanged: {}, sleep: FakeClock().sleep)
            model.refresh()
            t.check(spin { !model.checking }, "training: refresh completes")
            t.equal(model.jobError, "old failure", "training: refresh shows the latest job's error")
            t.equal(model.selectedModel, "small", "training: selection snaps to the served catalog")

            var modelsChanged = 0
            client.latestJob = job("done")
            let done = TrainingJobModel(client: client, onModelsChanged: { modelsChanged += 1 },
                                        sleep: FakeClock().sleep)
            done.refresh()
            t.check(spin { !done.checking }, "training: refresh of a done job completes")
            t.equal(modelsChanged, 1, "training: a done job refreshes custom models")
        }

        // Leaving the page cancels the poller; it's not an error.
        do {
            let client = FakeTrainingClient()
            client.statuses = [job("running")]
            let model = TrainingJobModel(client: client, onModelsChanged: {}, sleep: FakeClock().sleep)
            model.start()
            t.check(spin { client.statusCalls >= 3 }, "training: polling while running")
            model.stopPolling()
            spin(timeout: 0.1) { false }   // let the cancelled loop wind down
            let calls = client.statusCalls
            spin(timeout: 0.1) { false }
            t.equal(client.statusCalls, calls, "training: page leave stops polling")
            t.equal(model.jobError, nil, "training: cancel isn't an error")
        }
    }

    /// Runs the main run loop until `condition` holds (MainActor tasks resume
    /// there) or a short timeout passes.
    @discardableResult
    private static func spin(timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return condition()
    }
}
