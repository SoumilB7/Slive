import Foundation

/// One line on the pipe from Slive to its reporter (newline-delimited JSON).
/// Small on purpose: the app only says WHAT happened; the reporter, running in
/// its own process, gathers logs and stacks itself — so it works even when
/// Slive is frozen or gone.
public struct ReporterMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// First message: who the app is and what's switched on.
        case hello
        /// The app's settings summary changed.
        case context
        /// The watchdog thread is alive (the main thread may not be).
        case heartbeat
        /// The main thread hasn't answered for `seconds` (repeats while it lasts).
        case hang
        /// The main thread answered again after `seconds`.
        case hangEnded
        /// Something failed but Slive is still running.
        case failure
        /// "Report a Problem…" from the menu.
        case manual
        /// Slive is quitting normally — its exit is not a crash.
        case bye
    }

    public var kind: Kind
    public var seconds: Double?
    public var failure: Failure?
    /// Settings summary, already free of personal values (see `Context`).
    public var context: [String: String]?
    /// Whether to offer reports for automatic detections (manual always works).
    public var offerReports: Bool?

    public init(kind: Kind, seconds: Double? = nil, failure: Failure? = nil,
                context: [String: String]? = nil, offerReports: Bool? = nil) {
        self.kind = kind
        self.seconds = seconds
        self.failure = failure
        self.context = context
        self.offerReports = offerReports
    }

    public func encodedLine() -> Data? {
        guard var data = try? JSONEncoder().encode(self) else { return nil }
        data.append(0x0A)
        return data
    }
}

/// A failure the app caught while still running.
public struct Failure: Codable, Sendable, Equatable {
    /// Which part of Slive: "speech model", "microphone", "typing", "server", "storage", "shortcuts".
    public var area: String
    /// One plain sentence a person reads first ("The speech model failed to load.").
    public var title: String
    /// The error, as `Domain code: description` — cleaned again by the reporter.
    public var detail: String?
    /// `File.swift:123 function()` where it was caught.
    public var source: String
    /// Attach the server log's last lines (server failures).
    public var includeServerLog: Bool

    public init(area: String, title: String, detail: String?, source: String, includeServerLog: Bool = false) {
        self.area = area
        self.title = title
        self.detail = detail
        self.source = source
        self.includeServerLog = includeServerLog
    }

    /// Same failure at the same place = same issue (for "already offered").
    public var signature: String { "\(area)|\(title)|\(source)" }
}
