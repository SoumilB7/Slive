import Foundation

/// Owns the local Python transcription backend end-to-end:
/// - starts it on launch (reusing an already-running one instead of duplicating),
/// - keeps it alive with a watchdog that restarts it if it dies,
/// - brings it up **on demand** before a transcription so we never return an
///   empty result just because it wasn't running,
/// - publishes a `status` the UI can show.
///
/// Everything runs on the main actor; health probes are async (never block).
@MainActor
final class BackendManager: ObservableObject {
    enum Status: String {
        case offline = "Offline"
        case starting = "Starting…"
        case running = "Running"
    }

    @Published private(set) var status: Status = .offline

    private let port = 50711
    private let healthURL = URL(string: "http://127.0.0.1:50711/health")!
    private var process: Process?
    private var watchdog: Timer?

    /// Absolute path to the repo's Backend/ dir (baked at build time).
    private var backendDir: URL? {
        if let env = ProcessInfo.processInfo.environment["FLOWY_BACKEND_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "SliveBackendDir") as? String,
           !baked.isEmpty, !baked.contains("__BACKEND_DIR__") {
            return URL(fileURLWithPath: baked)
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Start the backend fresh and begin the watchdog.
    ///
    /// We deliberately do NOT reuse an already-running server: an orphan from a
    /// crash, or a stale process from before a backend code change, would serve
    /// old routes. So we kill any existing `flowy.server`, wait for the port to
    /// free, then spawn our own — every launch runs current code.
    func start() {
        Task {
            status = .starting
            pkillServer(signal: "TERM")
            // Wait until the old server stops answering (port released), then
            // spawn. Bounded so a wedged process can't hang startup.
            var waited = 0
            while await probeHealth() && waited < 20 {
                try? await Task.sleep(nanoseconds: 100_000_000)   // 0.1s
                waited += 1
            }
            if waited >= 20 { pkillServer(signal: "KILL") }        // force any holdout
            spawn()
            startWatchdog()
        }
    }

    /// Terminate the backend on quit — the one we started, plus any reused/orphan
    /// `flowy.server`, so ⌘Q always leaves nothing on the port. SIGTERM first for
    /// a clean uvicorn shutdown, then SIGKILL to guarantee nothing survives.
    func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        pkillServer(signal: "TERM")
        pkillServer(signal: "KILL")
        status = .offline
    }

    /// Ensure the backend answers `/health`, starting it and polling until it
    /// does (up to `timeout`). Returns whether it came up. Async sleeps between
    /// probes, so the main thread stays responsive (the overlay keeps its dots).
    func ensureHealthy(timeout: TimeInterval = 25) async -> Bool {
        if await probeHealth() { status = .running; return true }
        status = .starting
        spawnIfNeeded()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)   // 0.4s
            if await probeHealth() { status = .running; return true }
            // If our process died while we waited, bring it back.
            if !(process?.isRunning ?? false) { spawnIfNeeded() }
        }
        status = .offline
        return false
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        let t = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
            Task { await self?.watchdogTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func watchdogTick() async {
        if await probeHealth() {
            status = .running
        } else if !(process?.isRunning ?? false) {
            // No live server and nothing answering → (re)start it. If our process
            // IS alive but not answering yet, it's still loading — leave it be.
            status = .starting
            spawnIfNeeded()
        }
    }

    // MARK: - Spawn

    private func spawnIfNeeded() {
        if let p = process, p.isRunning { return }   // already ours
        spawn()
    }

    private func spawn() {
        guard let dir = backendDir else {
            NSLog("Slive: backend dir not configured — cannot start the server.")
            return
        }
        let python = dir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            NSLog("Slive: venv python missing at \(python.path) — run `uv sync` in Backend/.")
            return
        }

        let p = Process()
        p.executableURL = python
        p.arguments = ["-m", "flowy.server"]
        p.currentDirectoryURL = dir

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("slive-backend.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = handle
            p.standardError = handle
        }

        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.status = .offline
            }
        }

        do {
            try p.run()
            process = p
            status = .starting
            NSLog("Slive: backend starting (pid \(p.processIdentifier)). Log: \(logURL.path)")
        } catch {
            NSLog("Slive: failed to start backend — \(error)")
        }
    }

    // MARK: - Health

    private func probeHealth() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Kill every `flowy.server` process with the given signal ("TERM"/"KILL").
    /// Matches our own spawned server and any orphan/stale one on the port.
    private func pkillServer(signal: String = "TERM") {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-\(signal)", "-f", "flowy.server"]
        try? task.run()
        task.waitUntilExit()
    }
}
