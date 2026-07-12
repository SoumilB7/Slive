import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AudioModel()
    private lazy var overlay = OverlayController(model: model)
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let settingsWindow = SettingsWindowController()

    private var statusItem: NSStatusItem?
    private var recordStart: Date?
    private var autoHideWorkItem: DispatchWorkItem?

    private let minDuration: TimeInterval = 0.4

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon

        setupMenuBar()
        wireAudioAndHotkey()

        // Settings window + live hotkey switching.
        settingsWindow.audiosPath = audiosDirectory().path
        settingsWindow.onOpenAudios = { [weak self] in self?.openAudios() }
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

    // MARK: - Wiring

    private func wireAudioAndHotkey() {
        recorder.onLevels = { [weak self] bands, rms in
            self?.model.pushLevels(bands, rms: rms)
        }
        hotkey.onStart = { [weak self] in self?.startRecording() }
        hotkey.onStop = { [weak self] in self?.stopRecording() }
    }

    // MARK: - Record / Save flow

    private func startRecording() {
        guard !recorder.isRecording else { return }
        autoHideWorkItem?.cancel()

        model.beginListening()
        overlay.show()

        recordStart = Date()
        if !recorder.start() {
            model.fail("Mic unavailable")
            scheduleAutoHide()
        }
    }

    private func stopRecording() {
        guard recorder.isRecording else { return }
        let duration = recordStart.map { Date().timeIntervalSince($0) } ?? 0
        let wavURL = recorder.stop()

        // Discard accidental taps.
        if duration < minDuration || wavURL == nil {
            wavURL.map { try? FileManager.default.removeItem(at: $0) }
            model.tooShort()
            scheduleAutoHide()
            return
        }

        model.beginSaving()
        model.keepAnimating()

        let destination = audiosDirectory().appendingPathComponent(makeFilename())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let wavURL else { return }
            defer { try? FileManager.default.removeItem(at: wavURL) }
            do {
                let mp3 = try Mp3Encoder.encode(wavURL: wavURL, to: destination)
                NSLog("Flowy: saved \(mp3.path)")
                DispatchQueue.main.async {
                    self.model.finishSaved(seconds: duration)
                    self.scheduleAutoHide()
                }
            } catch {
                NSLog("Flowy: \(error)")
                DispatchQueue.main.async {
                    self.model.fail("Save failed")
                    self.scheduleAutoHide()
                }
            }
        }
    }

    private func scheduleAutoHide() {
        autoHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Don't hide if a new recording started in the meantime.
            if self.model.phase == .listening { return }
            self.model.reset()
            self.overlay.hide()
        }
        autoHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: work)
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
}

private extension NSStatusItem {
    /// Small helper so `setupMenuBar` reads cleanly.
    static func button(in bar: NSStatusBar) -> NSStatusItem {
        bar.statusItem(withLength: NSStatusItem.variableLength)
    }
}
