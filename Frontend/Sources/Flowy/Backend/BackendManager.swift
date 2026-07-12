import Foundation

/// Starts and stops the local Python transcription backend so you never have to
/// launch it from a terminal. It runs the existing uv virtualenv's Python
/// (`Backend/.venv/bin/python -m flowy.server`) as a child process, and kills it
/// when Flowy quits.
///
/// Only ever one backend runs: if something is already listening on the port
/// (e.g. an orphan from a force-quit, or a manually started server), we reuse it
/// instead of spawning a duplicate.
final class BackendManager {
    private let port = 50711
    private let healthURL = URL(string: "http://127.0.0.1:50711/health")!
    private var process: Process?

    /// Absolute path to the repo's Backend/ directory (baked at build time).
    private var backendDir: URL? {
        if let env = ProcessInfo.processInfo.environment["FLOWY_BACKEND_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "FlowyBackendDir") as? String,
           !baked.isEmpty, !baked.contains("__BACKEND_DIR__") {
            return URL(fileURLWithPath: baked)
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Launch the backend if it isn't already up. Non-blocking (runs the check +
    /// spawn off the main thread).
    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.isHealthy() {
                NSLog("Flowy: backend already running on :\(self.port) — reusing it.")
                return
            }
            self.spawn()
        }
    }

    /// Terminate the backend on quit. Terminates the process we started, AND
    /// pkills any `flowy.server` we merely *reused* (didn't spawn) — so ⌘Q always
    /// leaves nothing running on the port.
    func stop() {
        if let p = process, p.isRunning {
            NSLog("Flowy: stopping backend (pid \(p.processIdentifier))")
            p.terminate()
        }
        process = nil
        pkillServer()
    }

    /// Kill any lingering `flowy.server` process (the reused-orphan case).
    private func pkillServer() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "flowy.server"]
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Internals

    private func spawn() {
        guard let dir = backendDir else {
            NSLog("Flowy: backend dir not configured — cannot auto-start the server.")
            return
        }
        let python = dir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            NSLog("Flowy: venv python not found at \(python.path) — run `uv sync` in Backend/.")
            return
        }

        let p = Process()
        p.executableURL = python
        p.arguments = ["-m", "flowy.server"]
        p.currentDirectoryURL = dir

        // Route the server's output to a log file so we can debug without a terminal.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowy-backend.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = handle
            p.standardError = handle
        }

        // If the server dies on its own, drop our reference so a later start()
        // will spawn a fresh one.
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.process = nil }
        }

        do {
            try p.run()
            process = p
            NSLog("Flowy: backend started (pid \(p.processIdentifier)). Log: \(logURL.path)")
        } catch {
            NSLog("Flowy: failed to start backend — \(error)")
        }
    }

    /// Quick, blocking health probe (called off the main thread).
    private func isHealthy() -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1.5
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { ok = true }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 2.0)
        return ok
    }
}
