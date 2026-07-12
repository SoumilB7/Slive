import Foundation

/// Owns the local Python assistant backend end-to-end:
/// - reaps orphan servers at launch (without spawning one — the server starts
///   on demand, at the first assistant use, via `ensureHealthy`),
/// - re-spawns it inside `ensureHealthy` if it died,
/// - publishes a `status` the UI can show.
///
/// Everything runs on the main actor; health probes are async (never block).
@MainActor
final class BackendManager: ObservableObject {
    /// One backend per app — shared so both the assistant path and the
    /// training ground-truth path can ensureHealthy() the same server.
    static let shared = BackendManager()

    enum Status: String {
        case offline = "Offline"
        case starting = "Starting…"
        case running = "Running"
    }

    @Published private(set) var status: Status = .offline

    private let port = 50711
    private let healthURL = URL(string: "http://127.0.0.1:50711/health")!
    private var process: Process?

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

    /// Launch-time hygiene without the cost of running a server: kill any orphan
    /// `flowy.server` left over from a crashed session (it would sit on the port
    /// burning RAM), but do NOT spawn one. The server starts on demand — the
    /// assistant path's `ensureHealthy()` brings it up on first use — so a user
    /// who only dictates never pays for a resident Python process at all.
    func reapOrphans() {
        pkillServer(signal: "TERM")
        status = .offline
    }

    /// Terminate the backend on quit — the one we started, plus any reused/orphan
    /// `flowy.server`, so ⌘Q always leaves nothing on the port. SIGTERM first for
    /// a clean uvicorn shutdown, then SIGKILL to guarantee nothing survives.
    func stop() {
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

        // Run the interpreter under a "Slive Backend" name so Activity Monitor
        // shows it as Slive's, not "python3.13". Best-effort — falls back to the
        // plain venv python if the rename can't be set up.
        let launch = namedInterpreter(dir: dir, venvPython: python)

        let p = Process()
        p.executableURL = launch.exe
        p.arguments = ["-m", "flowy.server"]
        p.currentDirectoryURL = dir
        if let extraPath = launch.pythonPath {
            var env = ProcessInfo.processInfo.environment
            env["PYTHONPATH"] = env["PYTHONPATH"].map { "\(extraPath):\($0)" } ?? extraPath
            p.environment = env
        }

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
            NSLog("Slive: backend starting (pid \(p.processIdentifier)) as \(launch.exe.lastPathComponent).")
        } catch {
            NSLog("Slive: failed to start backend — \(error)")
        }
    }

    /// Resolve the venv's real interpreter and expose it under a "Slive Backend"
    /// hard link beside itself, so `execve` names the process after the link
    /// (macOS names a process after its real executable — a symlink won't do).
    /// The link lives next to the real python so its `@rpath` still resolves;
    /// because it then runs as the *base* interpreter (no venv auto-config), we
    /// hand it the venv site-packages + `src` via PYTHONPATH. Returns the plain
    /// venv python (no PYTHONPATH) if any step fails.
    private func namedInterpreter(dir: URL, venvPython: URL) -> (exe: URL, pythonPath: String?) {
        let fallback: (URL, String?) = (venvPython, nil)
        let real = venvPython.resolvingSymlinksInPath()
        let fm = FileManager.default
        // Must have resolved OUT of the venv to a real interpreter with a
        // sibling lib/ (so the hard link's @rpath finds libpython).
        guard real != venvPython, !real.path.contains("/.venv/"),
              fm.isExecutableFile(atPath: real.path) else { return fallback }

        let link = real.deletingLastPathComponent().appendingPathComponent("Slive Backend")
        if !fm.fileExists(atPath: link.path) {
            do { try fm.linkItem(at: real, to: link) }
            catch { NSLog("Slive: process rename skipped — \(error)"); return fallback }
        }

        // Find the venv site-packages (python3.x/site-packages).
        let lib = dir.appendingPathComponent(".venv/lib")
        guard let subs = try? fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil),
              let site = subs.first(where: { $0.lastPathComponent.hasPrefix("python") })?
                  .appendingPathComponent("site-packages"),
              fm.fileExists(atPath: site.path) else { return fallback }

        let src = dir.appendingPathComponent("src").path
        return (link, "\(site.path):\(src)")
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
