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
    private let transcriber = TranscriptionClient()
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

    /// How long a result box stays on screen before collapsing.
    private let resultDisplayDuration: TimeInterval = 6.0
    /// Assistant answers stay up longer — you need time to read them.
    private let assistantDisplayDuration: TimeInterval = 30.0

    /// How long you must hold the key before recording begins. Brief taps under
    /// this do nothing. Tune to taste.
    private let holdActivationDelay: TimeInterval = 0.3

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)   // normal app: Dock icon + Cmd-Tab

        // Keep the global hotkey + overlay alive when Flowy has no open window
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
        hotkey.hotkey = Settings.shared.hotkey
        hotkey.assistantHotkey = Settings.shared.assistantHotkey

        hotkey.start()   // self-arms once Input Monitoring is granted

        // First launch, or a missing permission → show the home window so the
        // user sees what Flowy does and can grant permissions in place.
        if Settings.shared.isFirstRun || !HotkeyMonitor.inputMonitoringGranted {
            openSettings()
            Settings.shared.markFirstRunComplete()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        backend.stop()   // shut the Python server down with the app
    }

    /// Clicking the Dock icon (no windows open) reopens the home window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    /// Closing the window must NOT quit Flowy — it keeps listening for the key.
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
    }

    // MARK: - Hold-to-talk flow

    private func keyDown(_ action: HotkeyAction) {
        // Arm: recording begins only if the key is still held after the delay.
        armWorkItem?.cancel()
        currentAction = action
        let work = DispatchWorkItem { [weak self] in
            self?.armWorkItem = nil
            self?.beginRecording()
        }
        armWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdActivationDelay, execute: work)
    }

    private func keyUp() {
        if let pending = armWorkItem {
            // Released before the hold threshold → do nothing at all.
            pending.cancel()
            armWorkItem = nil
            return
        }
        stopRecording()
    }

    private func beginRecording() {
        guard !recorder.isRecording else { return }
        // A new recording supersedes any pending transcription / result box.
        transcribeTask?.cancel()
        transcribeTask = nil
        collapseWorkItem?.cancel()
        collapseWorkItem = nil

        model.beginListening()
        overlay.show()
        recordStart = Date()
        if !recorder.start() {
            NSLog("Flowy: mic unavailable")
            model.finishListening()
            hideOverlaySoon()
        }
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

        // Encode to a TEMP MP3 that we delete right after — recordings are not
        // persisted; the audio only exists long enough to reach the backend.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowy-\(UUID().uuidString).mp3")
        let transcriber = self.transcriber
        // Captured on the main thread; sent as vocabulary hints to the backend.
        let hotwords = Settings.shared.hotwords
        let prompt = Settings.shared.contextPrompt
        // Which shortcut started this recording decides what we do with the text.
        let action = currentAction

        transcribeTask?.cancel()
        // Strong `self` capture: the task always returns (breaking any cycle),
        // and a new recording cancels it so a stale UI update never lands.
        transcribeTask = Task {
            // 1. Encode the WAV → MP3 (off the main thread).
            let mp3: URL
            do {
                mp3 = try await Self.encodeMp3(wavURL: wavURL, to: destination)
                NSLog("Flowy: encoded \(String(format: "%.1f", duration))s of audio")
            } catch {
                NSLog("Flowy: encode failed — \(error)")
                try? FileManager.default.removeItem(at: wavURL)
                await MainActor.run { self.finishTranscription(text: nil) }
                return
            }
            try? FileManager.default.removeItem(at: wavURL)
            defer { try? FileManager.default.removeItem(at: mp3) }   // never persisted

            if Task.isCancelled { return }

            // 2. Make sure the backend is actually up — start it and wait if it
            //    isn't — so a not-running server never yields an empty result.
            //    (The overlay keeps its loading dots during the wait.)
            let up = await self.backend.ensureHealthy()
            if Task.isCancelled { return }
            guard up else {
                await MainActor.run { self.showBackendError() }
                return
            }

            // 3. Transcribe. If it fails (server may have died mid-flight), bring
            //    the backend back and retry once before surfacing an error.
            var transcript: String?
            do {
                transcript = try await transcriber.transcribe(mp3, hotwords: hotwords, prompt: prompt)
            } catch {
                NSLog("Flowy: transcription failed — \(error); retrying after ensuring backend")
                if Task.isCancelled { return }
                if await self.backend.ensureHealthy() {
                    transcript = try? await transcriber.transcribe(mp3, hotwords: hotwords, prompt: prompt)
                }
            }
            if Task.isCancelled { return }
            guard let text = transcript else {
                await MainActor.run { self.showBackendError() }
                return
            }

            // 4. Route the transcript: plain dictation types/shows it; the
            //    assistant shortcut sends it to the LLM and shows the answer.
            switch action {
            case .dictate:
                await MainActor.run { self.finishTranscription(text: text) }
            case .assist:
                await self.runAssistant(on: text)
            }
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

        // Switch the overlay to the streaming answer box.
        model.beginStreaming()
        overlay.resize(to: OverlayMetrics.streamingPanelSize)
        overlay.setInteractive(true)

        var accumulated = ""
        do {
            for try await delta in assistant.askStream(question, config: config, apiKey: key) {
                if Task.isCancelled { return }
                accumulated += delta
                model.updateStreaming(accumulated)
            }
        } catch {
            if Task.isCancelled { return }
            if accumulated.isEmpty {
                finalizeAssist("⚠️ \(error)", collapseAfter: 6.0)
            } else {
                finalizeAssist(accumulated + "\n\n⚠️ \(error)")
            }
            return
        }
        if Task.isCancelled { return }
        finalizeAssist(accumulated)
    }

    /// Settle the streamed answer into a final, text-sized box (kept up longer
    /// so it can be read), and record it in history.
    @MainActor private func finalizeAssist(_ answer: String,
                                           collapseAfter seconds: TimeInterval? = nil) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            model.finishListening(); hideOverlaySoon(); return
        }
        HistoryStore.shared.add(trimmed)
        model.showResult(trimmed)   // clears streaming, sets final text
        overlay.resize(to: OverlayMetrics.panelSize(for: trimmed))
        overlay.setInteractive(true)
        scheduleCollapse(after: seconds ?? assistantDisplayDuration)
    }

    /// Encode on a background queue without blocking a cooperative-pool thread on
    /// `Process.waitUntilExit()`.
    private static func encodeMp3(wavURL: URL, to destination: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Mp3Encoder.encode(wavURL: wavURL, to: destination))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
        appMenu.addItem(withTitle: "About Flowy",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…",
                                       action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Flowy",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Flowy",
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
            accessibilityDescription: "Flowy"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let header = NSMenuItem(title: "Flowy", action: nil, keyEquivalent: "")
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
        menu.addItem(NSMenuItem(title: "Quit Flowy",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    /// Reflect the backend status in the menu-bar item (tooltip + menu line).
    private func updateBackendStatusUI(_ status: BackendManager.Status) {
        statusItem?.button?.toolTip = "Flowy — backend: \(status.rawValue)"
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

    /// Quit and reopen Flowy. Required after granting Input Monitoring, because
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
