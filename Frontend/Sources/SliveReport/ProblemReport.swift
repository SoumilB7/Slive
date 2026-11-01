import Foundation

/// One problem, ready to become a GitHub issue. Every string in it has already
/// been through `Redactor` — the reporter builds it only from cleaned parts.
public struct ProblemReport: Sendable {
    public enum Kind: String, Sendable {
        case crash, hang, failure, serverCrash, manual
    }

    public static let repository = "SoumilB7/Slive"

    public var kind: Kind
    /// Issue title after the kind tag: "EXC_BAD_ACCESS in TranscriptionModel.load(_:)".
    public var headline: String
    /// What happened, one or two plain sentences.
    public var summary: String
    /// Exception / error lines.
    public var details: [String]
    /// Stack (top first) or the failing call site.
    public var failurePoint: [String]
    public var build: BuildInfo
    public var system: SystemInfo
    /// Settings summary (keys and values are already non-personal).
    public var context: [String: String]
    public var occurredAt: Date
    /// Seconds Slive had been running when it happened.
    public var appUptime: TimeInterval?
    /// Slive's event log before the problem, oldest first ("-42.1s  decoded …").
    public var appLog: [String]
    /// The last lines of the Slive Server log.
    public var serverLog: [String]

    public init(kind: Kind, headline: String, summary: String, details: [String] = [],
                failurePoint: [String] = [], build: BuildInfo, system: SystemInfo,
                context: [String: String] = [:], occurredAt: Date = Date(),
                appUptime: TimeInterval? = nil, appLog: [String] = [], serverLog: [String] = []) {
        self.kind = kind
        self.headline = headline
        self.summary = summary
        self.details = details
        self.failurePoint = failurePoint
        self.build = build
        self.system = system
        self.context = context
        self.occurredAt = occurredAt
        self.appUptime = appUptime
        self.appLog = appLog
        self.serverLog = serverLog
    }

    public var title: String {
        let tag: String
        switch kind {
        case .crash: tag = "Crash"
        case .hang: tag = "Freeze"
        case .failure: tag = "Failure"
        case .serverCrash: tag = "Server crash"
        case .manual: tag = "Problem"
        }
        return "\(tag): \(headline) (\(build.version) \(build.commit))"
    }

    // MARK: - Markdown

    /// The issue body. `logLines` / `serverLines` / `frameLines` cap the long
    /// sections (most recent kept) so the whole thing fits in a URL.
    public func markdown(logLines: Int = 80, serverLines: Int = 40, frameLines: Int = 24) -> String {
        var md = "### What happened\n\(summary)\n\n"
        md += "<!-- Optional: what were you doing just before? -->\n\n"

        if !details.isEmpty || !failurePoint.isEmpty {
            md += "### Where it failed\n"
            for d in details { md += "**\(d.replacingOccurrences(of: "\n", with: " "))**  \n" }
            if !failurePoint.isEmpty {
                md += "```\n" + failurePoint.prefix(frameLines).joined(separator: "\n") + "\n```\n"
            }
            md += "\n"
        }

        md += "### Build\n"
        md += "| | |\n|---|---|\n"
        md += "| Slive | \(build.version) \(build.edition) |\n"
        var commit = "[\(build.commit)](https://github.com/\(Self.repository)/commit/\(build.cleanCommit))"
        if let d = build.commitDate { commit += " · committed \(Self.day.string(from: d))" }
        md += "| Commit | \(commit) |\n"
        md += "| macOS | \(system.macOS) |\n"
        md += "| Mac | \(system.chip) · \(system.memoryGB) GB |\n"
        var when = Self.utc.string(from: occurredAt) + " UTC"
        if let up = appUptime { when += " · \(Self.duration(up)) after launch" }
        md += "| When | \(when) |\n\n"

        if !context.isEmpty {
            md += "### Settings\n"
            md += context.sorted { $0.key < $1.key }
                .map { "`\($0.key)` \($0.value)" }.joined(separator: " · ") + "\n\n"
        }

        if !appLog.isEmpty, logLines > 0 {
            md += "### Slive log (last \(min(logLines, appLog.count)) events)\n"
            md += "```\n" + appLog.suffix(logLines).joined(separator: "\n") + "\n```\n\n"
        }
        if !serverLog.isEmpty, serverLines > 0 {
            md += "### Server log (last \(min(serverLines, serverLog.count)) lines)\n"
            md += "```\n" + serverLog.suffix(serverLines).joined(separator: "\n") + "\n```\n\n"
        }
        md += "<sub>Sent with Slive's problem reporter. Names, paths, device and app names, network addresses, keys and dictated text were removed on this Mac before this page opened.</sub>\n"
        return md
    }

    // MARK: - GitHub link

    /// GitHub refuses or truncates very long new-issue links; stay well under.
    public static let maxURLLength = 7_600

    /// A prefilled "New issue" page. The long sections shrink (oldest log
    /// lines first) until the link fits; nothing is posted until the person
    /// presses Submit on GitHub.
    public func issueURL() -> URL {
        var logs = min(appLog.count, 80)
        var server = min(serverLog.count, 40)
        var frames = min(failurePoint.count, 24)
        while true {
            let url = Self.newIssueURL(title: title, body: markdown(logLines: logs, serverLines: server, frameLines: frames))
            if url.absoluteString.count <= Self.maxURLLength { return url }
            if logs > 15 { logs -= 5 }
            else if server > 10 { server -= 5 }
            else if frames > 10 { frames -= 2 }
            else if logs > 0 { logs = max(0, logs - 5) }
            else if server > 0 { server = max(0, server - 5) }
            else if frames > 4 { frames -= 2 }
            else { return url }   // the fixed parts alone — can't shrink further
        }
    }

    public static func newIssueURL(title: String, body: String) -> URL {
        let base = "https://github.com/\(repository)/issues/new"
        let query = "title=\(encode(title))&body=\(encode(body))"
        return URL(string: base + "?" + query)!
    }

    /// Strict percent-encoding: only unreserved characters stay bare (a "+"
    /// or "&" left in would be read as a space or a new parameter).
    public static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    // MARK: - Formatting

    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 90 { return "\(s) s" }
        if s < 5400 { return "\(s / 60) min" }
        return String(format: "%.1f h", Double(s) / 3600)
    }
}
