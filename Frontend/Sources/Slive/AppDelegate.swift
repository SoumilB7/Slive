import AppKit
import AVFoundation
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AudioModel()
    private lazy var overlay = OverlayController(model: model)
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let settingsWindow = SettingsWindowController()
    private let whisper = TranscriptionModel.shared   // on-device STT (Neural Engine)
    private let assistant = AssistantClient()
    private let backend = BackendManager.shared

    private var statusItem: NSStatusItem?
    private var backendStatusItem: NSMenuItem?
    private var statusCancellable: AnyCancellable?
    private var recordStart: Date?
    /// Seconds spent speaking in the last dictation — used to compute WPM after
    /// the text is written (never in the hot path). Set when recording stops.
    private var lastSpeechDuration: TimeInterval = 0
    /// When the current continuous session began speaking (post hold-delay), so
    /// its pace can be measured on release.
    private var liveStart: Date?
    private var armWorkItem: DispatchWorkItem?
    private var activityToken: NSObjectProtocol?   // holds off App Nap
    private var transcribeTask: Task<Void, Never>? // in-flight encode + transcribe
    private var collapseWorkItem: DispatchWorkItem? // pending result auto-dismiss
    private var currentAction: HotkeyAction = .dictate  // which shortcut is recording

    /// Continuous (live streaming) dictation — a fully separate flow from the
    /// main press-and-release dictation so the two never interfere.
    private let continuous = ContinuousDictation()

    // In-memory assistant conversation (never persisted). `chatActive` is set
    // only by tapping "Continue"; the next assistant call then continues it.
    private var conversation: [AssistantClient.HistoryItem] = []
    private var chatActive = false
    private var pendingTurn: (question: String, answer: String)?

    /// How long the mic stays open AFTER the key is released. Releasing the key
    /// often overlaps the last word — stopping instantly clips its tail and
    /// the transcript loses the final word or two. A short grace captures it.
    private let releaseTail: TimeInterval = 0.20
    /// The delayed stop scheduled by `keyUp` (flushed early if a new hold begins).
    private var pendingStop: DispatchWorkItem?
    /// Last time the mic heard something voice-like (RMS above a floor). Lets
    /// `keyUp` skip the release tail when you already finished speaking — the
    /// tail only pays off when the release overlaps speech, so a quiet mic means
    /// the stop (and thus transcription) can start immediately.
    private var lastVoiceAt = Date.distantPast
    /// When the hotkey lifted — anchor for the always-on release→typed log.
    private var releasedAt: Date?

    /// How long a result box stays on screen before collapsing.
    private let resultDisplayDuration: TimeInterval = 6.0
    /// Assistant answers stay up longer — you need time to read them (dismiss
    /// early with the ✕ button).
    private let assistantDisplayDuration: TimeInterval = 15.0


    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)   // normal app: Dock icon + Cmd-Tab

        // Keep the global hotkey + overlay alive when Slive has no open window
        // and sits in the background — otherwise App Nap throttles the event tap.
        // Crucially `.userInitiatedAllowingIdleSystemSleep`, NOT `.userInitiated`:
        // the latter includes idleSystemSleepDisabled, which held the whole Mac
        // out of idle sleep for as long as Slive ran — a serious battery drain.
        // This variant prevents only App Nap; the machine sleeps normally.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled],
            reason: "Global push-to-talk listener"
        )

        // The Python backend serves only the assistant (STT is on-device), so
        // don't run it until the assistant is first used — `ensureHealthy()`
        // spawns it on demand. At launch just reap any orphan from a crashed
        // session. Saves a resident Python process for dictation-only use.
        backend.reapOrphans()
        statusCancellable = backend.$status.sink { [weak self] status in
            self?.updateBackendStatusUI(status)
        }

        setupMainMenu()
        setupMenuBar()
        wireAudioAndHotkey()

        // Settings window + live hotkey switching.
        settingsWindow.onRelaunch = { [weak self] in self?.relaunchApp() }
        Settings.shared.onHotkeyChange = { [weak self] hk in self?.hotkey.hotkey = hk }
        Settings.shared.onAssistantHotkeyChange = { [weak self] hk in self?.hotkey.assistantHotkey = hk }
        Settings.shared.onStreamHotkeyChange = { [weak self] hk in
            self?.hotkey.streamHotkey = hk
            // Recording/removing the continuous shortcut also decides whether its
            // model belongs in memory.
            self?.refreshModelResidency()
        }
        hotkey.hotkey = Settings.shared.hotkey
        hotkey.assistantHotkey = Settings.shared.assistantHotkey
        hotkey.streamHotkey = Settings.shared.streamHotkey

        // Preload the on-device transcription model IF it's already downloaded
        // (never auto-downloads — the user does that from Settings), and refresh
        // residency whenever a selection changes. The continuous model is only
        // kept in memory while a continuous shortcut is actually set — no point
        // holding a second model (RAM + ANE) for a feature that's switched off.
        Settings.shared.onWhisperModelChange = { [weak self] _ in self?.refreshModelResidency() }
        Settings.shared.onContinuousModelChange = { [weak self] _ in self?.refreshModelResidency() }
        whisper.migrateOldDownloadsIfNeeded()   // consolidate any prior downloads
        refreshModelResidency()

        hotkey.start()   // self-arms once Input Monitoring is granted

        // Pre-build the feedback tones off-main so the FIRST hold doesn't pay
        // the ~20ms synthesis + engine graph setup on the hot path.
        Task.detached(priority: .utility) { _ = FeedbackPlayer.shared }

        // First launch, or a missing permission → show the home window so the
        // user sees what Slive does and can grant permissions in place.
        if Settings.shared.isFirstRun || !HotkeyMonitor.inputMonitoringGranted {
            openSettings()
            Settings.shared.markFirstRunComplete()
        }
    }

    /// ⌘Q / Quit: tear everything down so nothing survives the app. Stop
    /// listening, cancel any in-flight transcription, release the on-device
    /// model from memory, kill the Python backend (ours + any orphan on the
    /// port), and end the background-activity assertion. `backend.stop()` is
    /// synchronous (it `waitUntilExit`s on pkill), so the server is gone before
    /// the process exits.
    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        transcribeTask?.cancel(); transcribeTask = nil
        continuous.cancel()  // stop any live stream
        whisper.shutdown()   // release the WhisperKit (Neural Engine) model
        backend.stop()       // shut the Python server down with the app
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    /// Keep exactly the models that are in use resident: dictation's always,
    /// continuous's only while its shortcut is set (same name = one shared
    /// instance). Everything else is evicted from RAM/ANE.
    private func refreshModelResidency() {
        var keep: Set<String> = [Settings.shared.whisperModel]
        if Settings.shared.streamHotkey != nil {
            keep.insert(Settings.shared.continuousModel)
        }
        whisper.retainModels(keep)
        for m in keep { whisper.select(m) }
    }

    /// Clicking the Dock icon (no windows open) reopens the home window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    /// Closing the window must NOT quit Slive — it keeps listening for the key.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Wiring

    private func wireAudioAndHotkey() {
        recorder.onLevels = { [weak self] bands, rms in
            self?.model.pushLevels(bands, rms: rms)
            // Voice-activity note for the adaptive release tail. The floor sits
            // above room noise but below quiet speech.
            if rms > 0.03 { self?.lastVoiceAt = Date() }
        }
        hotkey.onStart = { [weak self] action in self?.keyDown(action) }
        hotkey.onStop = { [weak self] _ in self?.keyUp() }
        model.onDismiss = { [weak self] in self?.dismissOverlay() }
        model.onContinue = { [weak self] in self?.continueChat() }
        continuous.onEnergy = { [weak self] energy in self?.model.pushStreamEnergy(energy) }
    }

    /// User tapped ✕ — cancel any in-flight work, end the chat, and collapse now.
    private func dismissOverlay() {
        transcribeTask?.cancel(); transcribeTask = nil
        collapseWorkItem?.cancel(); collapseWorkItem = nil
        continuous.cancel()
        chatActive = false
        conversation.removeAll()
        pendingTurn = nil
        collapseOverlay()
    }

    // MARK: - Hold-to-talk flow

    private func keyDown(_ action: HotkeyAction) {
        // A delayed stop may still be pending from the previous release — flush
        // it now (stop + hand off to transcription immediately) so the new hold
        // starts from a clean state instead of colliding with a live session.
        flushPendingStop()
        // Arm: recording begins only if the key is still held after the delay.
        armWorkItem?.cancel()
        currentAction = action
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.armWorkItem = nil
            if action == .stream { self.beginLiveDictation() }
            else { self.beginRecording() }
        }
        armWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.holdActivationDelay, execute: work)
    }

    private func keyUp() {
        if let pending = armWorkItem {
            // Released before the hold threshold → do nothing at all.
            pending.cancel()
            armWorkItem = nil
            return
        }
        // Don't stop the instant the key lifts — keep listening for a beat so
        // the tail of the last word makes it into the audio. The tail is
        // ADAPTIVE twice over: if the mic has already been quiet long enough,
        // skip it entirely; otherwise poll while it runs and stop the moment
        // ~110ms of silence has been observed (word endings decay in well
        // under that) instead of always paying the full 200ms. (Continuous
        // keeps the fixed tail: its voice activity isn't tracked by
        // `recorder.onLevels`.)
        pendingStop?.cancel()
        releasedAt = Date()   // anchors the release→typed timing log
        let action = currentAction
        if action == .stream {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStop = nil
                self.stopLiveDictation()
            }
            pendingStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + releaseTail, execute: work)
            return
        }
        if Date().timeIntervalSince(lastVoiceAt) > Self.tailSilence + 0.07 {
            stopRecording()
            return
        }
        armAdaptiveTail(startedAt: Date())
    }

    /// Observed post-release silence that ends the tail early — word tails
    /// decay in <100ms, and `lastVoiceAt` staleness (level coalescing) is
    /// bounded ~64ms, both inside this margin.
    private static let tailSilence: TimeInterval = 0.11

    /// The polling release tail: every 25ms, stop as soon as `tailSilence` of
    /// quiet has been seen — or when the full `releaseTail` elapses. Common
    /// case ("finish word, release") stops ~80–100ms sooner than the fixed
    /// wait did. The chained work item lives in `pendingStop`, so
    /// `flushPendingStop()` (a new hold starting) cancels the chain exactly
    /// like it cancelled the one-shot timer.
    private func armAdaptiveTail(startedAt: Date) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingStop != nil else { return }
            let quiet = Date().timeIntervalSince(self.lastVoiceAt)
            let elapsed = Date().timeIntervalSince(startedAt)
            if quiet >= Self.tailSilence || elapsed >= self.releaseTail {
                self.pendingStop = nil
                self.stopRecording()
            } else {
                self.armAdaptiveTail(startedAt: startedAt)
            }
        }
        pendingStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
    }

    /// Run the pending delayed stop right now (if any) — used when a new hold
    /// begins inside the release-tail window, so sessions never overlap.
    private func flushPendingStop() {
        guard pendingStop != nil else { return }
        pendingStop?.cancel()
        pendingStop = nil
        if currentAction == .stream { stopLiveDictation() }
        else { stopRecording() }
    }

    private func beginRecording() {
        guard !recorder.isRecording else { return }
        // A new recording supersedes any pending transcription / result box.
        transcribeTask?.cancel()
        transcribeTask = nil
        collapseWorkItem?.cancel()
        collapseWorkItem = nil

        model.beginListening(assistant: currentAction == .assist)
        if currentAction == .assist {
            // Boot the lazy backend NOW, overlapped with the user speaking —
            // by release it's healthy and the answer path skips the
            // multi-second first-use spawn entirely.
            Task { _ = await backend.ensureHealthy() }
        }
        overlay.show()
        recordStart = Date()
        if !recorder.start() {
            NSLog("Slive: mic unavailable")
            model.finishListening()
            hideOverlaySoon()
            return
        }
        // Subtle audio cue that a call activated — distinct per call type.
        // Posted on the NEXT runloop turn: its engine restart (auto-shutdown
        // wake) is a few ms of main-thread work that shouldn't sit between
        // key-down and the pill/mic being live.
        let cueAction = currentAction
        DispatchQueue.main.async { FeedbackPlayer.shared.playActivation(for: cueAction) }
    }

    private func stopRecording() {
        guard recorder.isRecording else { return }
        let duration = recordStart.map { Date().timeIntervalSince($0) } ?? 0
        lastSpeechDuration = duration   // for the post-write WPM measurement
        let capture = recorder.stop()
        let wavURL = capture.url
        let samples = capture.samples

        guard let wavURL else {
            model.finishListening()
            hideOverlaySoon()
            return
        }

        // Keep the overlay up and show a loading state while we save + transcribe.
        model.beginTranscribing()

        // Which shortcut started this recording decides what we do with the text.
        let action = currentAction
        let whisperModel = Settings.shared.whisperModel

        transcribeTask?.cancel()
        // Strong `self` capture: the task always returns (breaking any cycle),
        // and a new recording cancels it so a stale UI update never lands.
        transcribeTask = Task {
            defer { try? FileManager.default.removeItem(at: wavURL) }   // never persisted
            NSLog("Slive: captured \(String(format: "%.1f", duration))s of audio")
            if Task.isCancelled { return }

            // Assistant: capture the screenshot IN PARALLEL with transcription —
            // both happen post-release, and the screencapture subprocess used to
            // sit serially (~200-500ms) in front of the HTTP request.
            let screenshotTask: Task<(mediaType: String, data: String)?, Never>? =
                (action == .assist && Settings.shared.assistantConfig.attachScreenshot)
                ? Task.detached(priority: .userInitiated) { ScreenCapture.fullScreenBase64() }
                : nil

            // 1. Transcribe ON-DEVICE with WhisperKit (Neural Engine) — no backend
            //    needed for STT. Prefer the in-memory canonical samples the
            //    recorder accumulated (skips the WAV reopen/read); fall back to
            //    the file when they're unavailable (native-format fallback, or
            //    the model needs a load — the file path loads it).
            let tTranscribe = Date()
            var transcript: String?
            if samples.count > 16_000 / 3 {
                transcript = await whisper.transcribeSamples(samples, model: whisperModel)
            }
            if transcript == nil {
                transcript = await whisper.transcribe(wavURL, model: whisperModel)
            }
            // Unconditional: one line per dictation, and THE number to check
            // whenever "dictation feels slow" comes up again.
            NSLog("Slive: decoded %.1fs audio in %.2fs (%@)",
                  duration, Date().timeIntervalSince(tTranscribe), whisperModel)
            if Task.isCancelled { return }
            guard let text = transcript, !text.isEmpty else {
                await MainActor.run { self.handleNoTranscript() }
                return
            }

            // 2. Route the transcript: plain dictation types/shows it; the
            //    assistant shortcut needs the (always-on) Python backend to reach
            //    the LLM, so ensure it's up first, then stream the answer.
            switch action {
            case .dictate, .stream:
                // `.stream` never reaches here (it uses the live path), but the
                // file path falls back to plain dictation if it ever did.
                await MainActor.run { self.finishTranscription(text: text, audioURL: wavURL) }
            case .assist:
                if await self.backend.ensureHealthy() {
                    if Task.isCancelled { return }
                    await self.runAssistant(on: text, screenshot: screenshotTask)
                } else {
                    screenshotTask?.cancel()
                    await MainActor.run { self.showBackendError() }
                }
            }
        }
    }

    // MARK: - Live streaming dictation

    /// Start live dictation: stream transcription from the mic and type each
    /// confirmed word straight into the focused field as you speak, showing the
    /// still-forming tail in the overlay. Needs a model already loaded.
    private func beginLiveDictation() {
        guard !recorder.isRecording else { return }
        transcribeTask?.cancel(); transcribeTask = nil
        collapseWorkItem?.cancel(); collapseWorkItem = nil

        // Streaming can't wait on a first-time model load — it needs one in
        // memory now. If none is ready, tell the user and kick off a load.
        guard whisper.isReady(Settings.shared.continuousModel) else {
            whisper.select(Settings.shared.continuousModel)
            let msg = "Preparing the transcription model — hold again in a moment."
            model.showResult(msg)
            overlay.show()
            overlay.resize(to: OverlayMetrics.panelSize(for: msg))
            overlay.setInteractive(true)
            scheduleCollapse(after: 3.5)
            return
        }

        model.beginLiveDictation()
        overlay.show()   // same small waveform pill as normal dictation
        liveStart = Date()   // for the post-release WPM measurement
        DispatchQueue.main.async { FeedbackPlayer.shared.playActivation(for: .stream) }

        if !continuous.start() {
            model.finishListening()
            hideOverlaySoon()
        }
    }

    /// Stop live dictation: run the final accurate pass (which also catches the
    /// trailing audio), record the full text, and close the overlay. The pill
    /// shows the loading dots briefly while that final pass runs. If nothing
    /// could be typed live (no editable field was focused), the transcript is
    /// surfaced in the copy/dismiss result box instead — same as normal
    /// dictation — so the words are never silently lost.
    private func stopLiveDictation() {
        guard continuous.isActive else { return }
        // Timestamp the release now (before the final pass) so the measured pace
        // reflects speaking time, not the final-pass latency.
        let heldSeconds = liveStart.map { Date().timeIntervalSince($0) } ?? 0
        liveStart = nil
        model.beginTranscribing()
        Task { @MainActor in
            let outcome = await continuous.stop()
            if let releasedAt {
                NSLog("Slive: stream release→final %.2fs (tail+final pass)",
                      Date().timeIntervalSince(releasedAt))
                self.releasedAt = nil
            }
            let text = outcome.text
            if !text.isEmpty {
                HistoryStore.shared.add(text)
                SpeakingStats.shared.record(text: text, seconds: heldSeconds)  // after write
            }
            if !outcome.typed && !text.isEmpty {
                model.showResult(text)
                overlay.resize(to: OverlayMetrics.panelSize(for: text))
                overlay.setInteractive(true)          // copy button clickable
                scheduleCollapse(after: resultDisplayDuration)
            } else {
                model.finishListening()
                hideOverlaySoon()
            }
        }
    }

    /// Assistant path: stream the LLM's answer into a fixed-size box, growing
    /// the text as tokens arrive, then settle the box to the final size.
    @MainActor private func runAssistant(
        on transcript: String,
        screenshot screenshotTask: Task<(mediaType: String, data: String)?, Never>? = nil
    ) async {
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            model.finishListening(); hideOverlaySoon(); return
        }
        let config = Settings.shared.assistantConfig
        let key = Settings.shared.apiKey(for: config.provider)

        // Continue the previous chat only if the user tapped "Continue" after the
        // last answer; otherwise this is a fresh conversation.
        let continuing = chatActive
        chatActive = false
        if !continuing { conversation.removeAll() }
        let history = conversation.isEmpty ? nil : conversation

        // The screenshot was kicked off in parallel with transcription (see
        // stopRecording); by now it's usually already done — awaiting it here is
        // ~free instead of a serial ~200-500ms subprocess before the request.
        var images: [AssistantClient.ImageInput]? = nil
        if config.attachScreenshot {
            let shot: (mediaType: String, data: String)?
            if let screenshotTask {
                shot = await screenshotTask.value
            } else {
                // No pre-capture (e.g. setting flipped mid-flight) — capture now.
                shot = await Task.detached(priority: .userInitiated, operation: {
                    ScreenCapture.fullScreenBase64()
                }).value
            }
            if let shot {
                images = [AssistantClient.ImageInput(media_type: shot.mediaType, data: shot.data)]
            }
        }

        // Switch the overlay to the streaming answer box. When continuing, show
        // the prior turns above the new answer so it reads as one conversation.
        let priorTurns = conversation.map {
            AudioModel.ChatTurn(role: $0.role, text: $0.content)
        }
        model.beginStreaming(priorTurns: priorTurns, question: question)
        overlay.resize(to: OverlayMetrics.streamingPanelSize)
        overlay.setInteractive(true)

        var accumulated = ""
        var lastRender = Date.distantPast
        do {
            for try await delta in assistant.askStream(
                question, config: config, apiKey: key, images: images, history: history
            ) {
                if Task.isCancelled { return }
                accumulated += delta
                // Tokens often arrive in bursts; draining them straight through
                // on the main actor coalesces into a single paint. Update at most
                // ~30fps and briefly yield to the run loop so each frame actually
                // draws — the answer visibly types out.
                if Date().timeIntervalSince(lastRender) >= 0.033 {
                    lastRender = Date()
                    model.updateStreaming(accumulated)
                    try? await Task.sleep(nanoseconds: 3_000_000)
                }
            }
        } catch {
            if Task.isCancelled { return }
            let shown = accumulated.isEmpty ? "⚠️ \(error)" : accumulated + "\n\n⚠️ \(error)"
            showAssistantError(shown)
            return
        }
        if Task.isCancelled { return }
        finalizeAssist(question: question, answer: accumulated)
    }

    /// Settle the streamed answer into a final, text-sized box with a Continue
    /// footer, remember the turn (for a possible continuation), and record it.
    @MainActor private func finalizeAssist(question: String, answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pendingTurn = nil; model.finishListening(); hideOverlaySoon(); return
        }
        HistoryStore.shared.add(trimmed)
        pendingTurn = (question, trimmed)
        let wasChat = model.isChat
        model.showAssistantResult(trimmed)
        // Chat transcripts use the fixed scrolling box; a fresh single answer
        // sizes to its text.
        overlay.resize(to: wasChat ? OverlayMetrics.assistantStreamingPanelSize
                                   : OverlayMetrics.assistantPanelSize(for: trimmed))
        overlay.setInteractive(true)
        scheduleCollapse(after: assistantDisplayDuration)
    }

    /// Empty/failed transcript. If the model isn't ready, say so (with what to
    /// do); otherwise just fade the overlay (silence / a mis-hit key).
    @MainActor private func handleNoTranscript() {
        let message: String?
        switch whisper.status(for: Settings.shared.whisperModel) {
        case .notDownloaded:
            message = "Transcription model isn't downloaded yet — open Settings → General to download it."
        case .downloading(let p):
            message = "Downloading the transcription model… \(Int(p * 100))%"
        case .preparing(let stage):
            message = "Preparing the model (\(stage))…"
        case .failed(let e):
            message = "Transcription model failed to load: \(e)"
        case .ready:
            message = nil   // genuinely empty (silence) — just fade
        }
        guard let message else {
            model.finishListening(); hideOverlaySoon(); return
        }
        model.showResult(message)
        overlay.resize(to: OverlayMetrics.panelSize(for: message))
        overlay.setInteractive(true)
        scheduleCollapse(after: 5.0)
    }

    /// Show an assistant failure (no Continue footer) and collapse soon.
    @MainActor private func showAssistantError(_ text: String) {
        pendingTurn = nil
        model.showResult(text)
        overlay.resize(to: OverlayMetrics.panelSize(for: text))
        overlay.setInteractive(true)
        scheduleCollapse(after: 6.0)
    }

    /// User tapped "Continue": stash this turn into the conversation and hide the
    /// box (keeping chat state) so the next assistant keybind continues it.
    private func continueChat() {
        if let t = pendingTurn {
            conversation.append(AssistantClient.HistoryItem(role: "user", content: t.question))
            conversation.append(AssistantClient.HistoryItem(role: "assistant", content: t.answer))
        }
        pendingTurn = nil
        chatActive = true
        collapseWorkItem?.cancel(); collapseWorkItem = nil
        overlay.hide()   // hide() resets the model (chat state lives here, untouched)
    }

    /// Result path: grow the overlay to show `text`, then auto-collapse. On a nil
    /// (failure) or empty transcript, quietly fade the overlay away.
    @MainActor private func finishTranscription(text: String?, audioURL: URL? = nil) {
        transcribeTask = nil
        // Ignore stale completions — a new recording may already be listening.
        guard model.phase == .transcribing else { return }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            model.finishListening()
            hideOverlaySoon()
            return
        }

        // TYPE FIRST. The keystrokes are dispatched (or the copy box surfaced)
        // before any bookkeeping below, so nothing — history, the training
        // save, stats — can ever sit in front of the typeout. This ordering is
        // the guarantee; saving happens strictly after the text is on its way.
        let typed = Settings.shared.autoInsert && PasteEngine.insertIfPossible(trimmed)
        if let releasedAt {
            NSLog("Slive: release→typed %.2fs (tail+decode+dispatch)",
                  Date().timeIntervalSince(releasedAt))
            self.releasedAt = nil
        }
        if typed {
            model.finishListening()
            hideOverlaySoon()
        } else {
            // Auto-insert off (or blocked by a password field) → the copy box.
            model.showResult(trimmed)
            overlay.resize(to: OverlayMetrics.panelSize(for: trimmed))
            overlay.setInteractive(true)          // let the copy button be clicked
            scheduleCollapse(after: resultDisplayDuration)
        }

        // ---- Bookkeeping, strictly after the typeout dispatch ----
        HistoryStore.shared.add(trimmed)          // always keep it in the catalogue
        // Training pair (audio + transcript) — only while saving is toggled on
        // and under the size cap. Records regardless of where the text landed.
        if Settings.shared.captureEdits, !TrainingStore.shared.isOverLimit, let audioURL {
            TrainingStore.shared.addRecording(transcript: trimmed, audioURL: audioURL)
        }
        SpeakingStats.shared.record(text: trimmed, seconds: lastSpeechDuration)
    }

    private func scheduleCollapse(after seconds: TimeInterval) {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapseOverlay() }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func collapseOverlay() {
        collapseWorkItem = nil
        overlay.hide()   // hide() resets the model
    }

    private func hideOverlaySoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            if self.model.phase == .listening { return }   // a new hold began
            self.overlay.hide()   // hide() resets the model
        }
    }

    // MARK: - Main menu (standard app shortcuts)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu — About, Settings, Hide, Quit.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Slive",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…",
                                       action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Slive",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Slive",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — REQUIRED for Cut/Copy/Paste/Select All to work in text
        // fields. Without it, ⌘V (and ⌘C/⌘X/⌘A/⌘Z) have no menu item carrying
        // the key equivalent, so AppKit never dispatches them to the focused
        // field's editor — you literally can't paste an API key. These
        // nil-target selectors travel the responder chain to the field editor.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu — Minimize, Zoom, Close.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        let item = NSStatusItem.button(in: NSStatusBar.system)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Slive"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let header = NSMenuItem(title: "Slive", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // Live backend status (updated via the Combine subscription).
        let statusLine = NSMenuItem(title: "Backend: …", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        backendStatusItem = statusLine
        updateBackendStatusUI(backend.status)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        // Quit has no explicit target: it travels the responder chain to NSApp.
        menu.addItem(NSMenuItem(title: "Quit Slive",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    /// Reflect the backend status in the menu-bar item (tooltip + menu line).
    private func updateBackendStatusUI(_ status: BackendManager.Status) {
        statusItem?.button?.toolTip = "Slive — backend: \(status.rawValue)"
        backendStatusItem?.title = "Backend: \(status.rawValue)"
    }

    /// Shown when the backend couldn't be brought up in time — a clear message
    /// instead of an empty result.
    @MainActor private func showBackendError() {
        let msg = "Backend is still starting — hold and try again in a moment."
        model.showResult(msg)
        overlay.resize(to: OverlayMetrics.panelSize(for: msg))
        overlay.setInteractive(true)
        scheduleCollapse(after: 3.5)
    }

    /// Quit and reopen Slive. Required after granting Input Monitoring, because
    /// macOS caches that permission until the app is relaunched.
    @objc private func relaunchApp() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // Wait for THIS process to exit, then reopen the app — no double instance.
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(path)\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        NSApp.terminate(nil)
    }
}

private extension NSStatusItem {
    /// Small helper so `setupMenuBar` reads cleanly.
    static func button(in bar: NSStatusBar) -> NSStatusItem {
        bar.statusItem(withLength: NSStatusItem.variableLength)
    }
}
