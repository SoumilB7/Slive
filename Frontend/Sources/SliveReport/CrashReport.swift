import Foundation

/// What a macOS crash report (`~/Library/Logs/DiagnosticReports/Slive-….ips`)
/// says about a Slive crash — through an ALLOW-LIST: the exception, the
/// termination reason, Swift's fatal-error message and the crashing thread's
/// frames (image NAMES only). Everything else in the file — its path, user id,
/// crash-reporter key, UUIDs, parent process, other processes, raw instruction
/// bytes — is never read into the report.
public struct CrashReport: Sendable, Equatable {
    public var fileName: String
    public var time: Date?
    public var appVersion: String?
    /// "EXC_BAD_ACCESS (SIGSEGV) · KERN_INVALID_ADDRESS"
    public var exception: String
    /// Swift `fatalError` / precondition text, cleaned.
    public var messages: [String]
    /// The crashing thread, top first: "Slive  TranscriptionModel.load(_:) + 120 (TranscriptionModel.swift:977)"
    public var frames: [String]
    /// The topmost frame in Slive's own code, for the issue title.
    public var sliveFrame: String?

    /// `Slive-2026-11-05-160606.ips` (and `Slive-…-2.ips` for same-second ones),
    /// never the reporter's own or another app's.
    public static func isSliveCrashFile(_ name: String) -> Bool {
        name.range(of: #"^Slive-\d{4}-\d{2}-\d{2}-\d{6}(-\d+)?\.ips$"#, options: .regularExpression) != nil
    }

    public static func directory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Slive crash reports, newest first.
    public static func list(in dir: URL = directory()) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { isSliveCrashFile($0.lastPathComponent) }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.modified > $1.modified }
    }

    public static func parse(_ url: URL, redactor: Redactor) -> CrashReport? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, fileName: url.lastPathComponent, redactor: redactor)
    }

    public static func parse(_ text: String, fileName: String, redactor: Redactor) -> CrashReport? {
        // Line 1 is a small JSON header; the rest is the report body.
        guard let split = text.firstIndex(of: "\n"),
              let header = json(String(text[..<split])),
              let body = json(String(text[text.index(after: split)...])) else { return nil }

        let images: [String] = (body["usedImages"] as? [[String: Any]] ?? []).map { image in
            if let name = image["name"] as? String, !name.isEmpty { return name }
            if let path = image["path"] as? String { return (path as NSString).lastPathComponent }
            return "?"
        }

        var exception = "unknown"
        if let e = body["exception"] as? [String: Any] {
            var parts = [String]()
            if let type = e["type"] as? String {
                parts.append(type + ((e["signal"] as? String).map { " (\($0))" } ?? ""))
            }
            if let subtype = e["subtype"] as? String { parts.append(subtype) }
            if parts.isEmpty, let message = e["message"] as? String { parts.append(message) }
            if !parts.isEmpty { exception = redactor.cleanFreeText(parts.joined(separator: " · ")) }
        }
        if let t = body["termination"] as? [String: Any], let indicator = t["indicator"] as? String {
            exception += " · " + redactor.cleanFreeText(indicator)
        }

        var messages = [String]()
        if let asi = body["asi"] as? [String: Any] {
            for case let lines as [String] in asi.values {
                messages += lines.map { redactor.cleanFreeText(String($0.prefix(300))) }
            }
        }

        // An uncaught Objective-C exception's own backtrace beats the abort() thread.
        var rawFrames: [[String: Any]] = []
        if let last = body["lastExceptionBacktrace"] as? [[String: Any]], !last.isEmpty {
            rawFrames = last
        } else if let threads = body["threads"] as? [[String: Any]] {
            let index = body["faultingThread"] as? Int
                ?? threads.firstIndex { ($0["triggered"] as? Bool) == true } ?? 0
            if threads.indices.contains(index) {
                rawFrames = threads[index]["frames"] as? [[String: Any]] ?? []
            }
        }

        var frames = [String]()
        var sliveFrame: String?
        for frame in rawFrames.prefix(24) {
            let index = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) ? images[index] : "?"
            var line = image.padding(toLength: max(image.count, 18), withPad: " ", startingAt: 0)
            if let symbol = frame["symbol"] as? String {
                line += "  " + symbol
                if let offset = frame["symbolLocation"] as? Int { line += " + \(offset)" }
            } else if let offset = frame["imageOffset"] as? Int {
                line += "  +0x" + String(offset, radix: 16)
            }
            if let file = frame["sourceFile"] as? String {
                line += "  (" + (file as NSString).lastPathComponent
                    + ((frame["sourceLine"] as? Int).map { ":\($0)" } ?? "") + ")"
            }
            let clean = redactor.clean(line)
            frames.append(clean)
            if sliveFrame == nil, image == "Slive", let symbol = (frame["symbol"] as? String).flatMap(meaningfulSymbol) {
                sliveFrame = redactor.clean(symbol)
            }
        }

        let time = (header["timestamp"] as? String).flatMap(parseTimestamp)
        return CrashReport(fileName: fileName, time: time,
                           appVersion: header["app_version"] as? String,
                           exception: exception, messages: messages,
                           frames: frames, sliveFrame: sliveFrame)
    }

    /// A frame worth naming in a title: compiler thunks and `main` say
    /// nothing about where Slive went wrong (nil = keep looking deeper).
    public static func meaningfulSymbol(_ symbol: String) -> String? {
        if symbol.contains("thunk for") || symbol.contains("thunk helper") || symbol.hasPrefix("merged ") {
            return nil
        }
        let s = shortSymbol(symbol)
        return s.isEmpty || s == "main" ? nil : s
    }

    /// "closure #1 in TranscriptionModel.load(_:) (in Slive)" → "TranscriptionModel.load(_:)"
    static func shortSymbol(_ symbol: String) -> String {
        var s = symbol
        if let r = s.range(of: " in ", options: .backwards), s.hasPrefix("closure") || s.hasPrefix("partial apply") {
            s = String(s[r.upperBound...])
        }
        if let paren = s.range(of: " (") { s = String(s[..<paren.lowerBound]) }
        return String(s.prefix(90))
    }

    private static func json(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// "2026-11-05 16:06:06.00 +0530"
    private static func parseTimestamp(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
