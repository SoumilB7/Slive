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
    /// Why the last spawn couldn't even start (no backend dir, no venv,
    /// exec failed). Retrying can't help, so `ensureHealthy` returns at once
    /// and the UI can say what to fix instead of "still starting".
    @Published private(set) var lastSpawnError: String?

    /// How the last server we spawned ended. `wasExpected` = we stopped it
    /// (quit, idle shutdown) — anything else is a crash a reporter can flag.
    struct Exit: Equatable {
        let code: Int32
        let reason: Process.TerminationReason
        let wasExpected: Bool
        /// Seconds it ran (0 when a stop() had already let go of it).
        let uptime: TimeInterval
    }
    @Published private(set) var lastExit: Exit?

    /// A server that dies this soon after spawning is a quick death; this many
    /// in a row means it can't start (bad install, port taken), so respawning
    /// pauses for `crashCooldown` instead of looping through the whole
    /// ensureHealthy timeout (it used to respawn ~60× in 25s).
    nonisolated static let quickDeathSeconds: TimeInterval = 10
    nonisolated static let quickDeathLimit = 3
    private let crashCooldown: TimeInterval = 30
    private var quickDeaths = 0
    private var crashedOutUntil: Date?
    private var spawnedAt = Date()
    /// PIDs of servers we signalled ourselves, so their exit isn't a crash.
    private var expectedExits: Set<pid_t> = []

    /// Last time anything asked for the server. Idle this long with no
    /// download or training job running, it's stopped — it used to stay up
    /// until quit once anything (even opening Settings) had started it.
    private var lastUsed = Date()
    nonisolated static let idleShutdownSeconds: TimeInterval = 600
    private var idleTimer: Timer?

    /// `pgrep`/`pkill -f` regex for our server's argv (`… -m flowy.server`).
    /// Escaped and anchored: a bare `flowy.server` (dot = any char) also
    /// matched editors, `tail`s and dev servers that merely mention it.
    nonisolated static let serverPattern = "[-]m flowy\\.server( |$)"

    private let port = 50711
    private let healthURL = URL(string: "http://127.0.0.1:50711/health")!
    private var process: Process?

    /// Absolute path to the repo's Backend/ dir (baked at build time).
    private var backendDir: URL? {
        if Edition.bundledServer {
            return Bundle.main.resourceURL?.appendingPathComponent("backend", isDirectory: true)
        }
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
        status = .offline
        guard Edition.hasServer else { return }   // Lite ships no server to reap
        // PID-snapshot, then kill — far safer than killing by PATTERN later
        // (`pkill -f` would match our own future child), and it keeps the
        // fork/exec+wait off the launch path. Honest caveat: the snapshot is
        // taken inside this background task, not at call time, so a server we
        // spawn within the task's first ~100ms could theoretically be caught.
        // That window is all but unhittable at launch (an assistant call needs
        // user action first), and a caught server self-recovers — ensureHealthy
        // re-spawns on the next probe. The ownPid filter below excludes any
        // server we already own at call time.
        let ownPid = process?.processIdentifier
        Task.detached(priority: .utility) {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", BackendManager.serverPattern]
            let out = Pipe()
            pgrep.standardOutput = out
            guard (try? pgrep.run()) != nil else { return }
            pgrep.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let pids = String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) } ?? []
            for pid in pids where pid != ownPid { BackendManager.signal(pid, SIGTERM) }
            if !pids.isEmpty {
                NSLog("Slive: reaped \(pids.count) orphan backend process(es).")
            }
        }
    }

    /// Terminate the backend on quit — the one we started, plus any reused/orphan
    /// `flowy.server`, so ⌘Q always leaves nothing on the port. SIGTERM to the
    /// server's whole process group (it leads one, so a running training
    /// converter goes too), up to ~1.5s for a clean uvicorn shutdown, then
    /// SIGKILL for anything left. Blocking is fine here: it runs at quit, and
    /// the server must be gone before the app exits.
    func stop() {
        guard Edition.hasServer else { return }
        var pids = Set(Self.serverPIDs())
        if let p = process, p.isRunning {
            pids.insert(p.processIdentifier)
            expectedExits.insert(p.processIdentifier)
        }
        process = nil
        for pid in pids { Self.signal(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            usleep(50_000)
        }
        for pid in pids where kill(pid, 0) == 0 { Self.signal(pid, SIGKILL) }
        status = .offline
    }

    /// Ensure the backend answers `/health`, starting it and polling until it
    /// does (up to `timeout`). Returns whether it came up. Async sleeps between
    /// probes, so the main thread stays responsive (the overlay keeps its dots).
    func ensureHealthy(timeout: TimeInterval = 25) async -> Bool {
        guard Edition.hasServer else { return false }   // Lite ships no server
        lastUsed = Date()
        if await probeHealth() { status = .running; return true }
        status = .starting
        spawnIfNeeded()
        if lastSpawnError != nil, process == nil { status = .offline; return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)   // 0.4s
            if await probeHealth() { status = .running; return true }
            // If our process died while we waited, bring it back — unless it
            // keeps dying on start, which retrying can't fix.
            if !(process?.isRunning ?? false) {
                spawnIfNeeded()
                if lastSpawnError != nil, process == nil { break }
            }
        }
        status = .offline
        return false
    }

    // MARK: - Spawn

    private func spawnIfNeeded() {
        if let p = process {
            if p.isRunning { return }   // already ours
            processEnded(p)             // dead, handler not run yet — book it now
        }
        if let until = crashedOutUntil {
            if Date() < until { return }   // keeps dying on start; lastSpawnError says why
            crashedOutUntil = nil
            quickDeaths = 0
        }
        spawn()
    }

    private func spawn() {
        guard let dir = backendDir else {
            NSLog("Slive: backend dir not configured — cannot start the server.")
            lastSpawnError = "Server missing from this build."
            return
        }
        if Edition.bundledServer { spawnBundled(dir); return }
        let python = dir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            NSLog("Slive: venv python missing at \(python.path) — run `uv sync` in Backend/.")
            lastSpawnError = "Server setup missing (run `uv sync` in Backend)."
            return
        }

        // Run the interpreter under a "Slive Server" name so Activity Monitor
        // shows it as Slive's, not "python3.13". Best-effort — falls back to the
        // plain venv python if the rename can't be set up.
        let launch = namedInterpreter(dir: dir, venvPython: python)

        var env = ProcessInfo.processInfo.environment
        if let extraPath = launch.pythonPath {
            env["PYTHONPATH"] = env["PYTHONPATH"].map { "\(extraPath):\($0)" } ?? extraPath
        }
        // A Dock-launched app inherits launchd's bare PATH (/usr/bin:/bin:…);
        // the training pipeline shells out to tools (uv, the WhisperKit
        // converter) that live in the venv, ~/.local/bin or Homebrew.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let toolDirs = [dir.appendingPathComponent(".venv/bin").path, "\(home)/.local/bin",
                        "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (toolDirs + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"])
            .joined(separator: ":")
        // The server makes itself a process-group leader, so stop() can signal
        // it and its children (the training converter) together.
        env["SLIVE_PROCESS_GROUP"] = "1"
        startServer(launch.exe, arguments: ["-m", "flowy.server"], directory: dir, environment: env)

    }

    /// Start the server process (shared by the dev and bundled paths).
    private func startServer(_ exe: URL, arguments: [String], directory: URL, environment: [String: String]) {
        let p = Process()
        p.executableURL = exe
        p.arguments = arguments
        p.currentDirectoryURL = directory
        var environment = environment
        // The server watches this pid and leaves with us, crash included.
        environment["SLIVE_PARENT_PID"] = String(getpid())
        p.environment = environment

        // Keep the previous run's log: a server that died is only explained
        // by what it printed, and each respawn used to truncate it.
        let fm = FileManager.default
        let logURL = Self.logURL
        let prevURL = logURL.deletingLastPathComponent()
            .appendingPathComponent("slive-backend.prev.log")
        let logSize = ((try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber)?.intValue
        if (logSize ?? 0) > 0 {
            try? fm.removeItem(at: prevURL)
            try? fm.moveItem(at: logURL, to: prevURL)
        }
        fm.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = handle
            p.standardError = handle
        }

        p.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.processEnded(ended) }
        }

        do {
            try p.run()
            process = p
            spawnedAt = Date()
            status = .starting
            lastSpawnError = nil
            lastUsed = Date()
            armIdleShutdown()
            NSLog("Slive: backend starting (pid \(p.processIdentifier)) as \(exe.lastPathComponent).")
        } catch {
            NSLog("Slive: failed to start backend — \(error)")
            lastSpawnError = "Server didn't start: \(error.localizedDescription)"
        }
    }

    nonisolated static var logURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("slive-backend.log")
    }

    // MARK: - Exit bookkeeping

    /// Book a server's exit exactly once: record how it ended, forget it if
    /// it's still the current one, and stop respawning a server that keeps
    /// dying on start.
    private func processEnded(_ ended: Process) {
        let expected = expectedExits.remove(ended.processIdentifier) != nil
        let isCurrent = process === ended
        // Not current and not ours to stop = the respawn path booked it already.
        guard isCurrent || expected else { return }
        let uptime = isCurrent ? Date().timeIntervalSince(spawnedAt) : 0
        lastExit = Exit(code: ended.terminationStatus, reason: ended.terminationReason,
                        wasExpected: expected, uptime: uptime)
        // stop() has already let go of it.
        guard isCurrent else { return }
        process = nil
        status = .offline
        guard !expected else { return }
        NSLog("Slive: backend quit unexpectedly (\(Self.exitText(ended.terminationStatus, ended.terminationReason))) after \(Int(uptime))s.")
        quickDeaths = uptime < Self.quickDeathSeconds ? quickDeaths + 1 : 0
        guard quickDeaths >= Self.quickDeathLimit else { return }
        crashedOutUntil = Date().addingTimeInterval(crashCooldown)
        lastSpawnError = Self.deathReason(code: ended.terminationStatus,
                                          reason: ended.terminationReason,
                                          logTail: Self.logTail())
    }

    /// One short line for a server that keeps dying on start.
    nonisolated static func deathReason(code: Int32, reason: Process.TerminationReason,
                                        logTail: String) -> String {
        let log = logTail.lowercased()
        if log.contains("address already in use") || log.contains("errno 48") {
            return "Port 50711 is in use by another app."
        }
        return "Slive Server quit on start (\(exitText(code, reason)))."
    }

    nonisolated private static func exitText(_ code: Int32, _ reason: Process.TerminationReason) -> String {
        reason == .uncaughtSignal ? "signal \(code)" : "exit \(code)"
    }

    /// The last few KB of the server log, where a start-up failure lands.
    nonisolated private static func logTail() -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 4096 ? end - 4096 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// Release Full build: Python, its packages and the server source live in
    /// Contents/Resources/backend (python/, site-packages/, src/). The
    /// interpreter ships pre-named "Slive Server", and nothing is written into
    /// the signed app — no bytecode, and it runs from Application Support.
    private func spawnBundled(_ dir: URL) {
        let python = dir.appendingPathComponent("python/bin/Slive Server")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            lastSpawnError = "The bundled Slive Server is missing — reinstall Slive."
            return
        }
        let work = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Slive", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = [dir.appendingPathComponent("site-packages").path,
                             dir.appendingPathComponent("src").path].joined(separator: ":")
        env["PYTHONHOME"] = dir.appendingPathComponent("python").path
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["SLIVE_PROCESS_GROUP"] = "1"
        startServer(python, arguments: ["-m", "flowy.server"], directory: work, environment: env)
    }

    /// Resolve the venv's real interpreter and expose it under a "Slive Server"
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

        let link = real.deletingLastPathComponent().appendingPathComponent("Slive Server")
        removeLegacyLink(named: "Slive Backend", beside: real)
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

    /// Remove the interpreter hard link an older build created under its
    /// previous process name. Only a link to the SAME file as the real
    /// interpreter (same inode) is ever touched — removing a hard link leaves
    /// the interpreter itself intact.
    private func removeLegacyLink(named name: String, beside real: URL) {
        let fm = FileManager.default
        let legacy = real.deletingLastPathComponent().appendingPathComponent(name)
        guard let a = try? fm.attributesOfItem(atPath: legacy.path),
              let b = try? fm.attributesOfItem(atPath: real.path),
              let ia = a[.systemFileNumber] as? Int, let ib = b[.systemFileNumber] as? Int,
              ia == ib else { return }
        try? fm.removeItem(at: legacy)
    }

    // MARK: - Idle shutdown

    private func armIdleShutdown() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await BackendManager.shared.stopIfIdle() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func stopIfIdle() async {
        guard let p = process, p.isRunning else {
            idleTimer?.invalidate(); idleTimer = nil
            return
        }
        guard Date().timeIntervalSince(lastUsed) > Self.idleShutdownSeconds else { return }
        // A download or training job keeps it alive (an unreachable server
        // isn't idle-stopped either — the next ensureHealthy deals with it).
        guard let busy = await probeBusy(), !busy else { lastUsed = Date(); return }
        guard process === p, Date().timeIntervalSince(lastUsed) > Self.idleShutdownSeconds else { return }
        Log.event("backend idle 10 min — stopping it")
        idleTimer?.invalidate(); idleTimer = nil
        expectedExits.insert(p.processIdentifier)
        Self.signal(p.processIdentifier, SIGTERM)   // terminationHandler clears state
    }

    /// The server's `busy` flag, or nil if it didn't answer.
    private func probeBusy() async -> Bool? {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["busy"] as? Bool ?? false
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

    /// PIDs of every running `flowy.server` (ours and any orphan on the port).
    nonisolated private static func serverPIDs() -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", serverPattern]
        let out = Pipe()
        pgrep.standardOutput = out
        guard (try? pgrep.run()) != nil else { return [] }
        pgrep.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) } ?? []
    }

    /// Signal a server and, when it leads its own process group (servers we
    /// spawn do), every process in that group. A server from an older build
    /// leads no group, so the group signal finds nothing and is harmless.
    nonisolated static func signal(_ pid: pid_t, _ sig: Int32) {
        kill(-pid, sig)
        kill(pid, sig)
    }
}
