import CoreAudio
import Foundation

/// Makes text safe to publish in a public GitHub issue. Two layers:
///
/// 1. **This Mac's own identifiers, literally** — the macOS user name, the
///    owner's full name (and each part of it), the home folder, the computer
///    and host names, and the name of every audio device ("Soumil's AirPods").
/// 2. **Patterns** — any home path, temp folder, email, IP/MAC address,
///    UUID, API key or token, non-Slive URL, possessive device name, long
///    opaque blob.
///
/// Free text (dictated words, assistant replies, provider error bodies) has
/// no pattern a regex can trust, so it is stopped at the source: the report
/// reads only Slive's always-on event log, which never carries text, and
/// `cleanFreeText` additionally blanks anything quoted.
public struct Redactor: Sendable {
    private let literals: [(NSRegularExpression, String)]

    public init(userName: String, fullName: String, homeDirectory: String,
                hostNames: [String], deviceNames: [String]) {
        var pairs: [(String, String)] = []
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if home.count > 1 { pairs.append((home, "~")) }
        for d in deviceNames where d.count >= 3 { pairs.append((d, "<device>")) }
        for h in hostNames where h.count >= 3 {
            pairs.append((h, "<host>"))
            // "Soumils-MacBook-Air.local" ⇄ "Soumil's MacBook Air"
            pairs.append((h.replacingOccurrences(of: ".local", with: ""), "<host>"))
        }
        if fullName.count >= 3 { pairs.append((fullName, "<name>")) }
        for part in fullName.split(whereSeparator: { $0 == " " || $0 == "-" }) where part.count >= 3 {
            pairs.append((String(part), "<name>"))
        }
        if userName.count >= 3 { pairs.append((userName, "<user>")) }
        // Longest first, so "Soumil's AirPods" goes before "Soumil".
        pairs.sort { $0.0.count > $1.0.count }
        var seen = Set<String>()
        literals = pairs.compactMap { value, label in
            guard seen.insert(value.lowercased()).inserted else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: value)
            // A word-ish value only matches as a whole word ("Sam" ≠ "Sample").
            let first = value.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) } ?? false
            let last = value.unicodeScalars.last.map { CharacterSet.alphanumerics.contains($0) } ?? false
            let pattern = (first ? "(?<![\\p{L}\\p{N}])" : "") + escaped + (last ? "(?![\\p{L}\\p{N}])" : "")
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (re, label)
        }
    }

    /// The identifiers of the Mac this runs on.
    public static func forThisMac() -> Redactor {
        let info = ProcessInfo.processInfo
        var hosts = [info.hostName, Host.current().localizedName ?? ""]
        hosts += Host.current().names
        hosts = hosts.filter { !["localhost", "127.0.0.1", "::1"].contains($0.lowercased()) && !$0.isEmpty }
        return Redactor(userName: NSUserName(), fullName: NSFullUserName(),
                        homeDirectory: NSHomeDirectory(), hostNames: hosts,
                        deviceNames: audioDeviceNames())
    }

    // MARK: - Cleaning

    /// Identifiers and patterns removed; wording kept. For log lines, stack
    /// frames, settings values.
    public func clean(_ text: String) -> String {
        var s = text
        // Secrets and emails first: an email or key can contain the owner's
        // name, and naming it first would leave the rest of it behind.
        for rule in Self.rules.prefix(Self.earlyRules) { s = rule.re.replace(in: s, with: rule.template) }
        for (re, label) in literals { s = re.replace(in: s, with: label) }
        for rule in Self.rules.dropFirst(Self.earlyRules) { s = rule.re.replace(in: s, with: rule.template) }
        return Self.replaceOpaqueRuns(s)
    }

    /// `clean`, then anything quoted is blanked — for error messages and
    /// exception text, which can echo what was dictated or a provider reply.
    public func cleanFreeText(_ text: String) -> String {
        var s = clean(text)
        for rule in Self.quoteRules { s = rule.re.replace(in: s, with: rule.template) }
        return s
    }

    // MARK: - Rules

    private struct Rule { let re: NSRegularExpression; let template: String }
    private static func rule(_ pattern: String, _ template: String,
                             _ options: NSRegularExpression.Options = []) -> Rule {
        // Patterns are compile-time constants; SelfTest exercises every one.
        Rule(re: try! NSRegularExpression(pattern: pattern, options: options), template: template)
    }

    private static let allowedHosts = [
        "github.com", "raw.githubusercontent.com", "huggingface.co", "hf.co",
        "api.openai.com", "api.anthropic.com", "generativelanguage.googleapis.com",
        "openrouter.ai", "api.groq.com", "127.0.0.1", "localhost",
    ]

    /// How many of `rules` (secrets, emails) run before the literal names.
    private static let earlyRules = 3

    private static let rules: [Rule] = [
        // Secrets first, before anything can split them.
        rule(#"(?i)\b(authorization|x-goog-api-key|x-api-key|api[_-]?key|access[_-]?token|token|secret|password|passwd|bearer)(["']?\s*[:=]\s*|\s+)["']?(?:(?i:bearer|basic|token)\s+)?[^\s"',;&]{6,}"#, "$1$2<secret>"),
        rule(#"\b(sk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,}|AIza[0-9A-Za-z_\-]{20,}|hf_[A-Za-z0-9]{20,}|gsk_[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9\-]{10,}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,})"#, "<secret>"),
        // Emails before URLs and paths.
        rule(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
        // URLs: known services keep their host (never a query); anything else goes.
        rule(#"(?i)\b(https?|wss?|ftp)://(?!(?:"# + allowedHosts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")(?:[:/\s"'<>)\]]|$))[^\s"'<>)\]]+"#, "<url>"),
        rule(#"(?i)(\b(?:https?|wss?)://[^\s"'<>)\]?#]+)[?#][^\s"'<>)\]]*"#, "$1?<…>"),
        // Paths that name a person or a machine.
        rule(#"/Users/(?!Shared/)[^/\s"'<>:)\]]+"#, "/Users/<user>"),
        rule(#"(?:/private)?/var/folders/[^\s"'<>)\]]+"#, "<tmp>"),
        rule(#"/Volumes/[^/\s"'<>)\]]+"#, "/Volumes/<volume>"),
        rule(#"\b[A-Za-z0-9][A-Za-z0-9\-]*\.local\b"#, "<host>"),
        // Identifiers.
        rule(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<id>"),
        rule(#"\b(?:[0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}\b"#, "<mac>"),
        rule(#"\b(?!127\.0\.0\.1\b)(?!0\.0\.0\.0\b)(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b"#, "<ip>"),
        rule(#"(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}(?![\w:])"#, "<ip>"),
        // "Priya's AirPods", "Sam’s MacBook" — a possessive in a log line is a name.
        rule(#"\b(?!Slive\b|Apple\b|It\b|That\b|There\b|What\b|Here\b|Let\b)[\p{Lu}][\p{L}\-]{1,30}['’]s\b"#, "<name>'s"),
    ]

    /// Long opaque runs — keys we don't know, base64 audio, tokens: 40+
    /// characters mixing letters and digits, with at most two separators.
    /// (Model ids like `distil-whisper_distil-large-v3_turbo_600MB` are long
    /// too, but they're words joined by many separators — kept.)
    private static let longRun = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/=_\-]{40,}"#)

    static func isOpaque(_ token: Substring) -> Bool {
        let separators = token.filter { $0 == "-" || $0 == "_" }.count
        return separators <= 2 && token.contains(where: \.isNumber) && token.contains(where: \.isLetter)
    }

    private static func replaceOpaqueRuns(_ s: String) -> String {
        var out = s
        let matches = longRun.matches(in: s, range: NSRange(s.startIndex..., in: s))
        for m in matches.reversed() {
            guard let r = Range(m.range, in: out), isOpaque(out[r]) else { continue }
            out.replaceSubrange(r, with: "<blob>")
        }
        return out
    }

    private static let quoteRules: [Rule] = [
        rule(#"«[^»\n]*»"#, "«…»"),
        rule(#"“[^”\n]*”"#, "“…”"),
        rule(#""[^"\n]+""#, "\"…\""),
        rule(#"(?<![\p{L}\p{N}])'[^'\n]+'(?![\p{L}\p{N}])"#, "'…'"),
        rule(#"(?i)\b(input_value|input|text|prompt|content|transcript)\s*=\s*\S+"#, "$1=…"),
    ]

    // MARK: - Audio device names

    /// Every audio device's name — Bluetooth ones often carry the owner's
    /// name. Read straight from CoreAudio (no permission needed).
    public static func audioDeviceNames() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let value = name?.takeRetainedValue() as String?, !value.isEmpty else { return nil }
            return value
        }
    }
}

extension NSRegularExpression {
    func replace(in s: String, with template: String) -> String {
        stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
