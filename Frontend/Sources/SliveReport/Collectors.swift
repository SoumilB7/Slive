import Foundation

/// Gathers a report's evidence from outside the app's process, so it works
/// while Slive is frozen or after it crashed. Each source is read through
/// `Redactor` line by line before it can reach a report.
public enum Collectors {
    /// Slive's always-on event log (`Log.event`, subsystem com.slive.app) —
    /// public lines that by design carry timings, model ids and states, never
    /// dictated text. Developer logs (NSLog) are never read: they can hold
    /// error text, paths and device ids.
    /// Lines are stamped relative to `reference` ("-42.1s"), not wall-clock,
    /// so the log doesn't reveal the Mac's time zone.
    public static func eventLog(pid: Int32?, reference: Date, before: TimeInterval = 20 * 60,
                                redactor: Redactor, limit: Int = 120) -> [String] {
        // Slive's own event lines only — not other libraries logging under
        // the app's subsystem (WhisperKit does), whose wording we don't control.
        let predicate = "subsystem == \"com.slive.app\" AND category == \"events\""
            + (pid.map { " AND processID == \($0)" } ?? "")
        let window = DateFormatter()
        window.locale = Locale(identifier: "en_US_POSIX")
        window.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // Up to the problem (plus a second for its own lines), never after it.
        guard let out = run("/usr/bin/log", ["show", "--style", "ndjson", "--info",
                                             "--start", window.string(from: reference.addingTimeInterval(-before)),
                                             "--end", window.string(from: reference.addingTimeInterval(1)),
                                             "--predicate", predicate],
                            timeout: 25) else { return [] }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        var lines = [String]()
        for raw in out.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let message = entry["eventMessage"] as? String, !message.isEmpty else { continue }
            var stamp = "        "
            if let ts = entry["timestamp"] as? String, let date = parser.date(from: ts) {
                stamp = String(format: "%+8.1fs", date.timeIntervalSince(reference))
            }
            lines.append(stamp + "  " + String(redactor.cleanFreeText(message).prefix(240)))
        }
        return Array(lines.suffix(limit))
    }

    /// Where Slive Server writes stdout/stderr (BackendManager), and the
    /// previous run's copy.
    public static func serverLogURLs() -> [URL] {
        let tmp = FileManager.default.temporaryDirectory
        return [tmp.appendingPathComponent("slive-backend.prev.log"),
                tmp.appendingPathComponent("slive-backend.log")]
    }

    /// The server log's last lines, reduced to what's safe: access lines
    /// (method, path, status — no query), log records, traceback frames and
    /// exception TYPES with their message blanked of anything quoted.
    public static func serverLog(redactor: Redactor, limit: Int = 60) -> [String] {
        var lines = [String]()
        for url in serverLogURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }
            let tail = data.suffix(64 * 1024)   // a long-lived log can be large
            let text = String(decoding: tail, as: UTF8.self)
            lines += text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        return Array(lines.suffix(limit * 3).compactMap { serverLine($0, redactor: redactor) }.suffix(limit))
    }

    public static func serverLine(_ line: String, redactor: Redactor) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // Traceback frame: File "/Users/x/.slive/…/server.py", line 120, in transcribe
        if trimmed.hasPrefix("File \"") {
            return "  " + redactor.clean(trimmed)
        }
        // "ValueError: provider said …" → type + blanked message.
        if let match = trimmed.range(of: #"^[A-Za-z_][\w.]*(Error|Exception|Exit|Interrupt|Warning)\b:?"#,
                                     options: .regularExpression) {
            let type = String(trimmed[match])
            let rest = trimmed[match.upperBound...].trimmingCharacters(in: .whitespaces)
            return type + (rest.isEmpty ? "" : " " + String(redactor.cleanFreeText(rest).prefix(160)))
        }
        return String(redactor.cleanFreeText(line).prefix(240))
    }

    /// The main thread's stack while frozen. `sample` is Apple's profiler; it
    /// can read a process run by the same user. Its output file is deleted
    /// right after parsing.
    public static func sampleMainThread(pid: Int32, redactor: Redactor) -> HangSample? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("slive-hang-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = run("/usr/bin/sample", ["\(pid)", "2", "-mayDie", "-file", file.path], timeout: 20)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return HangSample.parse(text, redactor: redactor)
    }

    /// Run a tool and return its stdout, or nil if it failed or ran past
    /// `timeout` (it is then terminated). Output is drained as it arrives so a
    /// chatty tool can't fill the pipe and stall.
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let collected = Collected()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collected.append(chunk) }
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return String(decoding: collected.data, as: UTF8.self)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }
}
