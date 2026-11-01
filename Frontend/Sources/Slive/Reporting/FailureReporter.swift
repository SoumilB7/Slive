import AppKit
import AVFoundation
import SliveReport

/// Slive's side of problem reporting. At launch it starts the reporter — a
/// separate process (Contents/Helpers/SliveReporter.app) — and keeps a pipe
/// to it. A watchdog thread tells it when the main thread stops answering;
/// failure points call `report(…)`. The reporter does the rest (gathers logs
/// and stacks, removes anything personal, shows the panel), so it still
/// works while Slive is frozen or after it crashed.
///
/// Nothing ever blocks Slive: the pipe is non-blocking and a message that
/// doesn't fit is dropped.
final class FailureReporter: @unchecked Sendable {
    static let shared = FailureReporter()

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var helper: Process?
    private var restarts = 0
    private var started = false

    /// Main thread unanswered this long → tell the reporter (it shows a panel at 8 s).
    static let hangAfter: Double = 5
    /// Log any main-thread stall at least this long, even if it recovers.
    static let logStallAfter: Double = 2

    // MARK: - Lifecycle

    @MainActor
    func start() {
        guard !started else { return }
        started = true
        // A reporter that died mustn't take Slive with it on the next write.
        signal(SIGPIPE, SIG_IGN)
        launchHelper()
        send(ReporterMessage(kind: .hello, context: Self.context(), offerReports: Settings.shared.reportProblems))
        Thread.detachNewThread { [weak self] in self?.watchMainThread() }
    }

    /// Normal quit — the reporter must not read the exit as a crash.
    func goodbye() {
        send(ReporterMessage(kind: .bye))
    }

    /// A setting changed: refresh the reporter's copy of the summary.
    func settingsChanged() {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard started else { return }
                send(ReporterMessage(kind: .context, context: Self.context(),
                                     offerReports: Settings.shared.reportProblems))
            }
        }
    }

    /// "Report a Problem…"
    @MainActor
    func reportManually() {
        if helper?.isRunning != true { launchHelper() }
        send(ReporterMessage(kind: .manual, context: Self.context()))
    }

    // MARK: - Failures

    /// Something failed and Slive kept running. `title` is the plain sentence
    /// the person reads ("The speech model failed to load."); `error` adds
    /// its domain/code/description, which the reporter cleans again.
    /// Call it for real faults only — not for a missing permission, no
    /// network, a bad API key or a user cancel.
    func report(_ area: String, _ title: String, error: Error? = nil, detail: String? = nil,
                serverLog: Bool = false,
                file: String = #fileID, line: Int = #line, function: String = #function) {
        var text = detail
        if let error {
            let ns = error as NSError
            text = [text, "\(ns.domain) \(ns.code): \(ns.localizedDescription)"]
                .compactMap { $0 }.joined(separator: " · ")
        }
        let source = "\((file as NSString).lastPathComponent):\(line) \(function)"
        Log.event("failure (\(area)): \(title) at \(source)")
        send(ReporterMessage(kind: .failure,
                             failure: Failure(area: area, title: title, detail: text.map { String($0.prefix(600)) },
                                              source: source, includeServerLog: serverLog)))
    }

    /// A failed call to the local server: forwarded only when it's a fault
    /// (`reportable` — a 5xx, an unreadable reply), never a bad key, a
    /// cancel or a timeout. LocalServer calls this for every failure.
    func report(_ error: SliveError, area: String, title: String, detail: String? = nil,
                serverLog: Bool = false,
                file: String = #fileID, line: Int = #line, function: String = #function) {
        guard error.reportable else { return }
        report(area, title, error: error, detail: detail, serverLog: serverLog,
               file: file, line: line, function: function)
    }

    // MARK: - Helper process

    @MainActor
    private func launchHelper() {
        let exe = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/SliveReporter.app/Contents/MacOS/SliveReporter")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            Log.event("reporter: not in this build — problem reports off")
            return
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--pid", "\(ProcessInfo.processInfo.processIdentifier)",
                       "--app", Bundle.main.bundlePath,
                       "--launched", String(format: "%.0f", (Self.processStart ?? Date()).timeIntervalSince1970)]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] ended in
            // The reporter itself died (not at our quit): start a new one, a few times at most.
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.helper === ended, self.restarts < 3 else { return }
                    self.restarts += 1
                    Log.event("reporter exited (\(ended.terminationStatus)) — restarting it")
                    self.launchHelper()
                    self.send(ReporterMessage(kind: .hello, context: Self.context(),
                                              offerReports: Settings.shared.reportProblems))
                }
            }
        }
        do {
            try p.run()
        } catch {
            Log.event("reporter: couldn't start (\((error as NSError).code))")
            return
        }
        let writeFD = pipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        lock.lock()
        fd = dup(writeFD)
        lock.unlock()
        try? pipe.fileHandleForWriting.close()
        helper = p
    }

    private func send(_ message: ReporterMessage) {
        guard let data = message.encodedLine() else { return }
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EPIPE { close(fd); fd = -1 }
                break   // EAGAIN: reporter is behind — drop, never wait
            }
        }
    }

    // MARK: - Main-thread watchdog

    /// Pings the main queue once a second from its own thread. A ping that
    /// isn't answered within `hangAfter` means the main thread is stuck —
    /// the one thing Slive can't report about itself from the main thread.
    /// Uptime-based clocks pause while the Mac sleeps, so sleep is not a stall.
    private func watchMainThread() {
        Thread.current.name = "Slive watchdog"
        var lastHeartbeat = DispatchTime.now()
        while true {
            let sent = DispatchTime.now()
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            var told = false
            while answered.wait(timeout: .now() + 1) == .timedOut {
                let stuck = Self.seconds(since: sent)
                if stuck >= Self.hangAfter {
                    send(ReporterMessage(kind: .hang, seconds: stuck))
                    told = true
                }
            }
            let stalled = Self.seconds(since: sent)
            if stalled >= Self.logStallAfter {
                Log.event(String(format: "main thread blocked %.1fs", stalled))
            }
            if told { send(ReporterMessage(kind: .hangEnded, seconds: stalled)) }
            if Self.seconds(since: lastHeartbeat) >= 5 {
                send(ReporterMessage(kind: .heartbeat))
                lastHeartbeat = DispatchTime.now()
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private static func seconds(since t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e9
    }

    /// When this process started (for matching crash reports to this run).
    private static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, ProcessInfo.processInfo.processIdentifier]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()

    // MARK: - Context

    /// The settings a bug report needs — choices and states only. Never the
    /// mic's name, API keys, prompts, vocabulary or anything typed.
    @MainActor
    static func context() -> [String: String] {
        let s = Settings.shared
        let whisper = TranscriptionModel.shared
        func state(_ model: String) -> String {
            switch whisper.status(for: model) {
            case .ready: "ready"
            case .failed: "failed"
            case .preparing: "loading"
            case .downloading: "downloading"
            case .notDownloaded: "not downloaded"
            }
        }
        let continuousOn = (s.streamHoldOn && s.streamHotkey != nil)
            || (s.streamToggleOn && s.streamToggleHotkey != nil)
        var c: [String: String] = [
            "dictation model": "\(s.whisperModel) (\(state(s.whisperModel)))",
            "live typing": continuousOn ? "\(s.continuousModel) (\(state(s.continuousModel)))" : "off",
            "speed": s.resolvedSpeedTier.label,
            "hold delay": String(format: "%.2fs", s.holdActivationDelay),
            "type into apps": s.autoInsert ? "on" : "off",
            "echo cancellation": s.echoCancellation ? "on" : "off",
            "mic": s.inputDeviceUID.isEmpty ? "system default" : "chosen device",
            "permissions": [
                "mic " + (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "✓" : "✗"),
                "input monitoring " + (HotkeyMonitor.inputMonitoringGranted ? "✓" : "✗"),
                "accessibility " + (AXIsProcessTrusted() ? "✓" : "✗"),
            ].joined(separator: ", "),
        ]
        if Edition.hasServer {
            c["save dictations"] = s.captureEdits ? "on" : "off"
            c["assistant"] = s.assistantConfig.provider.rawValue
        }
        return c
    }
}
