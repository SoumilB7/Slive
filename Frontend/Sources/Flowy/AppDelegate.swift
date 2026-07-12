import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AudioModel()
    private lazy var overlay = OverlayController(model: model)
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let settingsWindow = SettingsWindowController()
    private let transcriber = TranscriptionClient()

    private var statusItem: NSStatusItem?
    private var recordStart: Date?
    private var armWorkItem: DispatchWorkItem?
    private var activityToken: NSObjectProtocol?   // holds off App Nap
    private var transcribeTask: Task<Void, Never>? // in-flight encode + transcribe
    private var collapseWorkItem: DispatchWorkItem? // pending result auto-dismiss

    /// How long a result box stays on screen before collapsing.
    private let resultDisplayDuration: TimeInterval = 4.0

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

        setupMainMenu()
        setupMenuBar()
        wireAudioAndHotkey()

        // Settings window + live hotkey switching.
        settingsWindow.audiosPath = audiosDirectory().path
        settingsWindow.onOpenAudios = { [weak self] in self?.openAudios() }
        settingsWindow.onRelaunch = { [weak self] in self?.relaunchApp() }
        Settings.shared.onHotkeyChange = { [weak self] choice in self?.hotkey.choice = choice }
        hotkey.choice = Settings.shared.hotkey

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
        hotkey.onStart = { [weak self] in self?.keyDown() }
        hotkey.onStop = { [weak self] in self?.keyUp() }
    }

    // MARK: - Hold-to-talk flow

    private func keyDown() {
        // Arm: recording begins only if the key is still held after the delay.
        armWorkItem?.cancel()
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

        let destination = audiosDirectory().appendingPathComponent(makeFilename())
        let transcriber = self.transcriber

        transcribeTask?.cancel()
        // Strong `self` capture: the task always returns (breaking any cycle),
        // and a new recording cancels it so a stale UI update never lands.
        transcribeTask = Task {
            // 1. Encode the WAV → MP3 (off the main thread). The file is always
            //    saved, even if the transcription step later fails.
            let mp3: URL
            do {
                mp3 = try await Self.encodeMp3(wavURL: wavURL, to: destination)
                NSLog("Flowy: saved \(mp3.path) (\(String(format: "%.1f", duration))s)")
            } catch {
                NSLog("Flowy: save failed — \(error)")
                try? FileManager.default.removeItem(at: wavURL)
                await MainActor.run { self.finishTranscription(text: nil) }
                return
            }
            try? FileManager.default.removeItem(at: wavURL)

            if Task.isCancelled { return }

            // 2. Send it to the backend and await the transcript.
            do {
                let text = try await transcriber.transcribe(mp3)
                if Task.isCancelled { return }
                await MainActor.run { self.finishTranscription(text: text) }
            } catch {
                NSLog("Flowy: transcription failed — \(error)")
                if Task.isCancelled { return }
                await MainActor.run { self.finishTranscription(text: nil) }
            }
        }
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

        model.showResult(trimmed)
        overlay.resize(to: OverlayMetrics.panelSize(for: trimmed))
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

    // MARK: - Paths

    private func audiosDirectory() -> URL {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FLOWY_AUDIOS_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "FlowyAudiosPath") as? String,
           !baked.isEmpty, !baked.contains("__AUDIOS_DIR__") {
            return URL(fileURLWithPath: baked)
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Flowy Audios")
    }

    private func makeFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "flowy-\(f.string(from: Date())).mp3"
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
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let openItem = NSMenuItem(title: "Open Recordings Folder",
                                  action: #selector(openAudios), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())
        // Quit has no explicit target: it travels the responder chain to NSApp.
        menu.addItem(NSMenuItem(title: "Quit Flowy",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        settingsWindow.audiosPath = audiosDirectory().path
        settingsWindow.show()
    }

    @objc private func openAudios() {
        let dir = audiosDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
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
