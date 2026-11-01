import AppKit
import AVFoundation
import Combine

/// App lifecycle and the wiring between the long-lived objects (built by
/// `AppContainer`). What a gesture does lives in the modes (`ModeRegistry`:
/// Dictate, Assist, Stream), the gesture rules in `SessionCoordinator`, the
/// overlay's in `OverlayPresenter`, model residency in `ModelResidency`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppContainer()

    var presenter: OverlayPresenter { app.presenter }
    var whisper: TranscriptionModel { app.whisper }
    var backend: BackendManager { app.backend }
    var session: SessionCoordinator { app.session }
    var residency: ModelResidency { app.residency }

    private var activityToken: NSObjectProtocol?   // holds off App Nap
    /// Keeps the problem reporter's settings summary current and tells it
    /// when the server dies on its own.
    private var reporterWatches: Set<AnyCancellable> = []
    /// The `Settings.changes` subscription (lives as long as the app).
    private var settingsChanges: AnyCancellable?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)   // normal app: Dock icon + Cmd-Tab
        // First: the problem reporter (its own process) and the main-thread
        // watchdog, so even a crash or freeze during launch can be reported.
        FailureReporter.shared.start()

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
        backend.$lastExit.compactMap { $0 }.filter { !$0.wasExpected }.sink { exit in
            let how = exit.reason == .uncaughtSignal ? "signal \(exit.code)" : "exit code \(exit.code)"
            FailureReporter.shared.report("server", "Slive Server stopped unexpectedly.",
                                          detail: "\(how) after \(Int(exit.uptime)) s", serverLog: true)
        }.store(in: &reporterWatches)
        Settings.shared.objectWillChange.merge(with: whisper.objectWillChange)
            // Throttle, not debounce: a steady stream of model updates must
            // not hold the summary back (a freeze report used launch-time states).
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { FailureReporter.shared.settingsChanged() }
            .store(in: &reporterWatches)

        app.menuBar.install()
        wireAudioAndHotkey()

        // Settings window + live hotkey switching.
        app.settingsWindow.onRelaunch = { [weak self] in self?.relaunchApp() }
        settingsChanges = Settings.shared.changes.sink { [weak self] change in
            self?.settingsChanged(change)
        }
        syncBindings()

        // Preload the on-device transcription model IF it's already downloaded
        // (never auto-downloads — the user does that from Settings), and refresh
        // residency whenever a selection changes (`settingsChanged`). The
        // continuous model is only kept in memory while a continuous shortcut
        // is actually set — no point holding a second model (RAM + ANE) for a
        // feature that's switched off.
        whisper.onModelReady = { [weak self] model in self?.residency.modelReady(model) }
        whisper.migrateOldDownloadsIfNeeded()   // consolidate any prior downloads
        residency.refresh()

        app.hotkey.start()   // self-arms once Input Monitoring is granted

        // Pre-build the feedback tones off-main so the FIRST hold doesn't pay
        // the ~20ms synthesis + engine graph setup on the hot path.
        Task.detached(priority: .utility) { _ = FeedbackPlayer.shared }

        DebugHooks.install()

        // First launch, or a missing permission → show the home window so the
        // user sees what Slive does and can grant permissions in place.
        if Settings.shared.isFirstRun || !HotkeyMonitor.inputMonitoringGranted {
            app.menuBar.openSettings()
            Settings.shared.markFirstRunComplete()
            // Ask for the mic here, beside the permission list — otherwise the
            // first prompt came mid-hold and that dictation was lost to it.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
        }
    }

    /// ⌘Q / Quit: tear everything down so nothing survives the app. Stop
    /// listening, cancel any in-flight transcription, release the on-device
    /// model from memory, kill the Python backend (ours + any orphan on the
    /// port), and end the background-activity assertion. `backend.stop()` is
    /// synchronous (it `waitUntilExit`s on pkill), so the server is gone before
    /// the process exits.
    func applicationWillTerminate(_ notification: Notification) {
        FailureReporter.shared.goodbye()   // a normal quit, not a crash
        app.hotkey.stop()
        app.work.cancelRequest()
        app.dictations.cancelAll()
        app.modes.dismissAll()  // stop any live stream
        TrainingStore.shared.flushPendingWrites()   // labels from a run in flight
        whisper.shutdown()   // release the WhisperKit (Neural Engine) model
        backend.stop()       // shut the Python server down with the app
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    /// Clicking the Dock icon (no windows open) reopens the home window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app.menuBar.openSettings() }
        return true
    }

    /// Closing the window must NOT quit Slive — it keeps listening for the key.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quit and reopen Slive. Required after granting Input Monitoring, because
    /// macOS caches that permission until the app is relaunched.
    @objc private func relaunchApp() {
        FailureReporter.shared.goodbye()
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

    // MARK: - Wiring

    /// Settings that take effect live. Runs synchronously inside the setter,
    /// so the monitor and residency see the new value immediately — and
    /// always bindings first, then residency.
    private func settingsChanged(_ change: SettingsChange) {
        switch change {
        case .bindings:
            syncBindings()
            // Recording/removing the continuous shortcut (or flipping a stream
            // switch) also decides whether its model belongs in memory — a
            // stream toggle also earns the model RAM.
            residency.refresh()
        case .dictationModel, .continuousModel:
            residency.refresh()
        }
    }

    /// Push the EFFECTIVE bindings into the monitor: a bind whose on/off
    /// switch is off simply isn't a binding, nor is an action this build
    /// can't run (Lite: no assistant).
    private func syncBindings() {
        app.hotkey.bindings = HotkeyBinding.effective(from: Settings.shared, capabilities: .current)
    }

    private func wireAudioAndHotkey() {
        let model = app.overlayModel
        // Voice recency for the release tail lives in the recorder itself
        // (per-callback, no dispatch staleness) — levels here are visuals only.
        app.recorder.onLevels = { [weak model] bands, rms in
            model?.pushLevels(bands, rms: rms)
        }
        // Begin / end look the action up; Continue, the stream's energy and
        // its failure are wired by the modes themselves.
        session.handler = app.modes
        let session = self.session
        app.hotkey.onStart = { [weak session] action in session?.keyDown(action) }
        app.hotkey.onStop = { [weak session] _ in session?.keyUp() }
        model.onDismiss = { [weak self] in self?.dismissOverlay() }
        app.hotkey.onToggle = { [weak session] action in session?.toggleTapped(action) }
    }

    /// User tapped ✕ — cancel any in-flight work, end the chat, and collapse now.
    /// Released dictations are NOT cancelled: their words were spoken, so they
    /// still type (or surface a copy box) when decoded.
    private func dismissOverlay() {
        app.work.cancelRequest()
        session.endToggle()
        app.modes.dismissAll()   // queued assistant requests, the chat, a live stream
        presenter.dismiss()
    }
}
