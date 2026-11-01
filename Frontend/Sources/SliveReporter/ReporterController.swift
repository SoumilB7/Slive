import AppKit
import SliveReport

/// Watches one running Slive from outside it. Slive pipes it a few small
/// messages (heartbeats, "main thread blocked", caught failures); the
/// reporter notices on its own when Slive dies. When something is worth
/// reporting it shows a small panel that opens a prefilled GitHub issue —
/// and because it is a separate process, it still works when Slive is
/// frozen or has crashed.
@MainActor
final class ReporterController {
    private let pid: Int32
    private let appURL: URL
    private let launchedAt: Date
    private let build: BuildInfo
    private let system = SystemInfo.current()
    private let redactor = Redactor.forThisMac()
    private var state = ReporterState.load()

    private var context: [String: String] = [:]
    private var offerReports = true
    private var lastHeard = ReporterController.uptime()
    private var said = false            // any message at all yet
    private var bye = false             // Slive is quitting normally
    private var weEndedIt = false       // we killed it (Restart)
    private var relaunchWhenGone = false
    private var parentGone = false
    private var processSource: DispatchSourceProcess?
    private var silenceTimer: Timer?
    private var stdinBuffer = Data()

    private var panel: ReportPanel?
    /// The freeze the panel is about (nil = none showing).
    private var hangSeconds: Double?
    private var hangRecovered = false

    /// Show the "not responding" panel once the main thread has been stuck this long.
    static let hangPanelAfter: Double = 8
    /// No word at all from Slive (not even its watchdog thread) for this long = frozen solid.
    static let silenceIsHangAfter: Double = 30
    /// How long to wait for macOS to write the crash report after Slive dies.
    static let crashReportWait: TimeInterval = 20

    init(pid: Int32, appURL: URL, launchedAt: Date) {
        self.pid = pid
        self.appURL = appURL
        self.launchedAt = launchedAt
        self.build = BuildInfo(bundle: Bundle(url: appURL) ?? .main)
    }

    func start() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.parentExited() }
        }
        source.resume()
        processSource = source
        // Already gone before we started watching (crashed during launch).
        if kill(pid, 0) != 0, errno == ESRCH { parentExited() }

        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(chunk) }
            }
        }

        silenceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSilence() }
        }
    }

    // MARK: - Messages from Slive

    private func received(_ chunk: Data) {
        if chunk.isEmpty {   // pipe closed: Slive is gone (the process source confirms)
            FileHandle.standardInput.readabilityHandler = nil
            return
        }
        stdinBuffer.append(chunk)
        while let newline = stdinBuffer.firstIndex(of: 0x0A) {
            let line = stdinBuffer[stdinBuffer.startIndex..<newline]
            stdinBuffer.removeSubrange(stdinBuffer.startIndex...newline)
            // A torn line (non-blocking writes may drop) is skipped; the next one resyncs.
            if let message = try? JSONDecoder().decode(ReporterMessage.self, from: Data(line)) {
                handle(message)
            }
        }
    }

    private func handle(_ m: ReporterMessage) {
        lastHeard = Self.uptime()
        let first = !said
        said = true
        if let c = m.context { context = c.mapValues { redactor.clean($0) } }
        if let offer = m.offerReports { offerReports = offer }

        switch m.kind {
        case .hello:
            if first { offerUnreportedCrash() }
        case .context, .heartbeat:
            break
        case .hang:
            frozen(for: m.seconds ?? 0)
        case .hangEnded:
            unfrozen(after: m.seconds ?? 0)
        case .failure:
            if let f = m.failure { failed(f) }
        case .manual:
            manualReport()
        case .bye:
            bye = true
        }
    }

    private func checkSilence() {
        guard !parentGone, said, !bye, panel == nil, offerReports else { return }
        let silent = Self.uptime() - lastHeard
        if silent >= Self.silenceIsHangAfter { frozen(for: silent) }
    }

    // MARK: - Freeze

    private func frozen(for seconds: Double) {
        if hangSeconds != nil, !hangRecovered {
            hangSeconds = seconds
            panel?.model.subtitle = "No response for \(ProblemReport.duration(seconds))."
            panel?.model.report?.summary = hangSummary(seconds, recovered: false)
            return
        }
        guard seconds >= Self.hangPanelAfter, offerReports, panel == nil else { return }
        hangSeconds = seconds
        hangRecovered = false

        let model = PanelModel(kind: .hang, title: "Slive isn't responding",
                               subtitle: "No response for \(ProblemReport.duration(seconds)).")
        model.secondaryTitle = "Restart Slive"
        model.dismissTitle = "Wait"
        show(model, signature: nil)

        // Sample the stuck thread NOW, while it's stuck.
        let pid = self.pid, redactor = self.redactor, reference = Date()
        let base = baseReport(kind: .hang, headline: "main thread stopped responding",
                              summary: hangSummary(seconds, recovered: false))
        Task.detached(priority: .userInitiated) {
            let sample = Collectors.sampleMainThread(pid: pid, redactor: redactor)
            let log = Collectors.eventLog(pid: pid, reference: reference, redactor: redactor)
            await MainActor.run { [weak self] in
                guard let self, self.panel?.model === model else { return }
                var report = base
                if let frame = sample?.sliveFrame { report.headline = "main thread stuck in \(frame)" }
                report.failurePoint = sample?.frames ?? ["(the stack couldn't be sampled)"]
                report.appLog = log
                report.summary = self.hangSummary(self.hangSeconds ?? seconds, recovered: self.hangRecovered)
                model.report = report
            }
        }
    }

    private func unfrozen(after seconds: Double) {
        guard hangSeconds != nil, let panel, panel.model.kind == .hang else { return }
        hangSeconds = seconds
        hangRecovered = true
        panel.model.title = "Slive is responding again"
        panel.model.subtitle = "It froze for \(ProblemReport.duration(seconds)). A report helps fix it."
        panel.model.secondaryTitle = nil
        panel.model.dismissTitle = "Close"
        panel.model.report?.summary = hangSummary(seconds, recovered: true)
    }

    private func hangSummary(_ seconds: Double, recovered: Bool) -> String {
        "Slive's main thread stopped responding for \(ProblemReport.duration(seconds))"
            + (recovered ? " and then recovered." : " (still frozen when this report was made).")
    }

    // MARK: - Failure Slive caught

    private func failed(_ f: Failure) {
        guard offerReports, panel == nil, !state.recentlyOffered(f.signature) else { return }
        let detail = f.detail.map { redactor.cleanFreeText($0) }
        let model = PanelModel(kind: .failure, title: redactor.clean(f.title),
                               subtitle: detail.map { String($0.prefix(140)) } ?? "Slive kept running. A report helps fix it.")
        show(model, signature: f.signature)

        var base = baseReport(kind: .failure, headline: redactor.clean(f.title),
                              summary: redactor.clean(f.title) + " (" + f.area + ")")
        base.details = detail.map { [$0] } ?? []
        base.failurePoint = ["caught at " + redactor.clean(f.source)]
        gatherLogs(into: base, model: model, includeServer: f.includeServerLog)
    }

    private func manualReport() {
        if let panel, panel.model.kind == .manual { panel.orderFront(); return }
        guard panel == nil else { panel?.orderFront(); return }
        let model = PanelModel(kind: .manual, title: "Report a problem",
                               subtitle: "Opens a GitHub issue with Slive's recent log. You describe what went wrong.")
        model.primaryTitle = "Open GitHub"
        model.dismissTitle = "Cancel"
        show(model, signature: nil)
        let base = baseReport(kind: .manual, headline: "describe the problem",
                              summary: "<!-- What went wrong, and what did you expect? -->")
        gatherLogs(into: base, model: model, includeServer: build.edition == "Full")
    }

    private func gatherLogs(into base: ProblemReport, model: PanelModel, includeServer: Bool) {
        let pid = self.pid, redactor = self.redactor, reference = base.occurredAt
        Task.detached(priority: .userInitiated) {
            let log = Collectors.eventLog(pid: pid, reference: reference, redactor: redactor)
            let server = includeServer ? Collectors.serverLog(redactor: redactor) : []
            await MainActor.run {
                var report = base
                report.appLog = log
                report.serverLog = server
                model.report = report
            }
        }
    }

    // MARK: - Crash

    private func parentExited() {
        guard !parentGone else { return }
        parentGone = true
        processSource?.cancel()
        silenceTimer?.invalidate()

        if relaunchWhenGone {
            relaunchWhenGone = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            panel?.close()
            panel = nil
        }
        if bye || weEndedIt { finishIfIdle(); return }

        // Not a normal quit: crashed (macOS writes a report within seconds),
        // or killed (an update, Force Quit) — then no report appears.
        let deadline = Date().addingTimeInterval(Self.crashReportWait)
        Task { @MainActor in
            while Date() < deadline {
                if let file = newCrashFile(since: launchedAt.addingTimeInterval(-2)) {
                    crashed(file)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if let panel, panel.model.kind == .hang {
                panel.model.title = "Slive was closed while frozen"
                panel.model.subtitle = "Froze for \(ProblemReport.duration(hangSeconds ?? 0)). A report helps fix it."
                panel.model.secondaryTitle = "Reopen Slive"
                panel.model.dismissTitle = "Close"
            }
            finishIfIdle()
        }
    }

    private func newCrashFile(since: Date) -> URL? {
        CrashReport.list().first { $0.modified >= since && !state.seenCrashFiles.contains($0.url.lastPathComponent) }?.url
    }

    private func crashed(_ file: URL) {
        state.markSeen(file.lastPathComponent)
        guard offerReports else { finishIfIdle(); return }
        if let existing = panel { existing.close(); panel = nil }
        presentCrash(file, summary: "Slive quit unexpectedly.", uptime: Date().timeIntervalSince(launchedAt))
    }

    /// A crash from an earlier run that nobody was asked about (the reporter
    /// wasn't running, or it happened during launch).
    private func offerUnreportedCrash() {
        let threeDays: TimeInterval = 3 * 24 * 3600
        let unseen = CrashReport.list().filter {
            !state.seenCrashFiles.contains($0.url.lastPathComponent)
                && $0.modified < launchedAt && Date().timeIntervalSince($0.modified) < threeDays
        }
        unseen.forEach { state.markSeen($0.url.lastPathComponent) }
        guard offerReports, panel == nil, let newest = unseen.first else { return }
        presentCrash(newest.url, summary: "Slive quit unexpectedly the last time it ran.", uptime: nil)
    }

    private func presentCrash(_ file: URL, summary: String, uptime: TimeInterval?) {
        let model = PanelModel(kind: .crash, title: "Slive quit unexpectedly", subtitle: "Reading the crash report…")
        model.secondaryTitle = parentGone ? "Reopen Slive" : nil
        model.dismissTitle = "Close"
        show(model, signature: nil)

        let redactor = self.redactor
        var base = baseReport(kind: .crash, headline: "Slive crashed", summary: summary)
        base.appUptime = uptime
        let pid: Int32? = uptime == nil ? nil : self.pid
        Task.detached(priority: .userInitiated) {
            let crash = CrashReport.parse(file, redactor: redactor)
            let reference = crash?.time ?? Date()
            // A crash from an earlier run: that run's pid is unknown, so the
            // 20 minutes of Slive events before the crash time.
            let log = Collectors.eventLog(pid: pid, reference: reference, redactor: redactor, limit: 80)
            await MainActor.run {
                var report = base
                if let crash {
                    let place = crash.sliveFrame.map { " in \($0)" } ?? ""
                    let exception = crash.exception.components(separatedBy: " · ").first ?? crash.exception
                    report.headline = exception + place
                    report.details = [crash.exception] + crash.messages
                    report.failurePoint = crash.frames
                    if let t = crash.time { report.occurredAt = t }
                } else {
                    report.details = ["(the crash report couldn't be read)"]
                }
                report.appLog = log
                model.subtitle = report.headline
                model.report = report
            }
        }
    }

    // MARK: - Panel

    private func baseReport(kind: ProblemReport.Kind, headline: String, summary: String) -> ProblemReport {
        ProblemReport(kind: kind, headline: headline, summary: summary, build: build, system: system,
                      context: context, occurredAt: Date(),
                      appUptime: parentGone ? nil : Date().timeIntervalSince(launchedAt))
    }

    private func show(_ model: PanelModel, signature: String?) {
        model.onReport = { [weak self] report in
            NSWorkspace.shared.open(report.issueURL())
            if let signature { self?.state.markOffered(signature) }
            self?.closePanel()
        }
        model.onSecondary = { [weak self] in self?.secondaryAction(for: model) }
        model.onDismiss = { [weak self] in
            if let signature { self?.state.markOffered(signature) }
            self?.closePanel()
        }
        let p = ReportPanel(model: model)
        panel = p
        p.present()
    }

    private func secondaryAction(for model: PanelModel) {
        if parentGone {   // Reopen
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            closePanel()
            return
        }
        // Restart a frozen Slive: TERM, then KILL if it can't even die; relaunch once it's gone.
        weEndedIt = true
        relaunchWhenGone = true
        model.subtitle = "Restarting…"
        kill(pid, SIGTERM)
        let pid = self.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    private func closePanel() {
        panel?.close()
        panel = nil
        hangSeconds = nil
        hangRecovered = false
        finishIfIdle()
    }

    /// The reporter lives as long as its Slive, plus any panel left open.
    private func finishIfIdle() {
        if parentGone && panel == nil && !relaunchWhenGone { NSApp.terminate(nil) }
    }

    static func uptime() -> Double {
        // Mach absolute time stops while the Mac sleeps, so a lid closed
        // mid-heartbeat never looks like a freeze.
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }
}
