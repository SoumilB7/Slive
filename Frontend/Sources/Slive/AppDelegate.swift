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
    private let backend = BackendManager()

    private var statusItem: NSStatusItem?
    private var backendStatusItem: NSMenuItem?
    private var statusCancellable: AnyCancellable?
    private var recordStart: Date?
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
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled],
            reason: "Global push-to-talk listener"
        )

        // Auto-start the local transcription backend so it's ready by the time
        // you record — no terminal needed. Stopped again in applicationWillTerminate.
        backend.start()
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
        Settings.shared.onStreamHotkeyChange = { [weak self] hk in self?.hotkey.streamHotkey = hk }
        hotkey.hotkey = Settings.shared.hotkey
        hotkey.assistantHotkey = Settings.shared.assistantHotkey
        hotkey.streamHotkey = Settings.shared.streamHotkey

        // Preload the on-device transcription model IF it's already downloaded
        // (never auto-downloads — the user does that from Settings). Refresh the
        // status when the selected model changes.
        // Dictation and continuous dictation each keep their OWN model. On either
        // change, evict anything no longer referenced by the two sections, then
        // preload the new one (shared as one instance when the names match).
        Settings.shared.onWhisperModelChange = { [weak self] m in
            self?.whisper.retainModels([m, Settings.shared.continuousModel])
            self?.whisper.select(m)
        }
        Settings.shared.onContinuousModelChange = { [weak self] m in
            self?.whisper.retainModels([Settings.shared.whisperModel, m])
            self?.whisper.select(m)
        }
        whisper.migrateOldDownloadsIfNeeded()   // consolidate any prior downloads
        whisper.select(Settings.shared.whisperModel)
        whisper.select(Settings.shared.continuousModel)
        whisper.retainModels([Settings.shared.whisperModel, Settings.shared.continuousModel])

        hotkey.start()   // self-arms once Input Monitoring is granted

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
        overlay.show()
        recordStart = Date()
        if !recorder.start() {
            NSLog("Slive: mic unavailable")
            model.finishListening()
            hideOverlaySoon()
            return
        }
        // Subtle audio cue that a call activated — distinct per call type.
        FeedbackPlayer.shared.playActivation(for: currentAction)
    }

    private func stopRecording() {
        guard recorder.isRecording else { return }
        let duration = recordStart.map { Date().timeIntervalSince($0) } ?? 0
        let wavURL = recorder.stop()

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

            // 1. Transcribe ON-DEVICE with WhisperKit (Neural Engine) — no backend
            //    needed for STT. Returns nil if the model isn't ready (not
            //    downloaded / still preparing) — we then tell the user instead of
            //    hanging on the spinner.
            let transcript = await whisper.transcribe(wavURL, model: whisperModel)
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
                await MainActor.run { self.finishTranscription(text: text) }
            case .assist:
                if await self.backend.ensureHealthy() {
                    if Task.isCancelled { return }
                    await self.runAssistant(on: text)
                } else {
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
        FeedbackPlayer.shared.playActivation(for: .stream)

        if !continuous.start() {
            model.finishListening()
            hideOverlaySoon()
        }
    }

    /// Stop live dictation: run the final accurate pass (which also catches the
    /// trailing audio), record the full text, and close the overlay. The pill
    /// shows the loading dots briefly while that final pass runs.
    private func stopLiveDictation() {
        guard continuous.isActive else { return }
        model.beginTranscribing()
        Task { @MainActor in
            let full = await continuous.stop()
            if !full.isEmpty { HistoryStore.shared.add(full) }
            model.finishListening()
            hideOverlaySoon()
        }
    }

    /// Assistant path: stream the LLM's answer into a fixed-size box, growing
    /// the text as tokens arrive, then settle the box to the final size.
    @MainActor private func runAssistant(on transcript: String) async {
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

        // Optionally attach a full-screen screenshot (captured off the main
        // thread so the blocking subprocess doesn't stall the UI).
        var images: [AssistantClient.ImageInput]? = nil
        if config.attachScreenshot {
            if let shot = await Task.detached(priority: .userInitiated, operation: {
                ScreenCapture.fullScreenBase64()
            }).value {
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
        overlay.hide()
        model.reset()
    }

    /// Result path: grow the overlay to show `text`, then auto-collapse. On a nil
    /// (failure) or empty transcript, quietly fade the overlay away.
    @MainActor private func finishTranscription(text: String?) {
        transcribeTask = nil
        // Ignore stale completions — a new recording may already be listening.
        guard model.phase == .transcribing else { return }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            model.finishListening()
            hideOverlaySoon()
            return
        }

        HistoryStore.shared.add(trimmed)          // always keep it in the catalogue

        // If auto-insert is on and a text field is focused, paste straight there
        // and skip the copy box entirely.
        if Settings.shared.autoInsert, PasteEngine.insertIfPossible(trimmed) {
            model.finishListening()
            hideOverlaySoon()
            return
        }

        // Otherwise, surface the copy box.
        model.showResult(trimmed)
        overlay.resize(to: OverlayMetrics.panelSize(for: trimmed))
        overlay.setInteractive(true)              // let the copy button be clicked
        scheduleCollapse(after: resultDisplayDuration)
    }

    private func scheduleCollapse(after seconds: TimeInterval) {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapseOverlay() }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func collapseOverlay() {
        collapseWorkItem = nil
        overlay.hide()
        model.reset()
    }

    private func hideOverlaySoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            if self.model.phase == .listening { return }   // a new hold began
            self.overlay.hide()
            self.model.reset()
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
