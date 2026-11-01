import Foundation

/// Which Slive this is — read from the app bundle's Info.plist (build.sh bakes
/// the commit in), so a report points at the exact code that failed.
public struct BuildInfo: Sendable, Equatable {
    public var version: String
    public var edition: String
    /// Short commit hash, `-dirty` when built from uncommitted changes.
    public var commit: String
    /// The commit's date (ISO 8601), when the build recorded it.
    public var commitDate: Date?

    public init(version: String, edition: String, commit: String, commitDate: Date?) {
        self.version = version
        self.edition = edition
        self.commit = commit
        self.commitDate = commitDate
    }

    public init(bundle: Bundle) {
        func value(_ key: String) -> String? {
            guard let s = bundle.object(forInfoDictionaryKey: key) as? String,
                  !s.isEmpty, !s.hasPrefix("__") else { return nil }
            return s
        }
        version = value("CFBundleShortVersionString") ?? "?"
        edition = value("SliveEdition") == "lite" ? "Lite" : "Full"
        commit = value("SliveBuild") ?? "unknown"
        commitDate = value("SliveBuildDate").flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// The hash without `-dirty`, for a commit link.
    public var cleanCommit: String {
        commit.hasSuffix("-dirty") ? String(commit.dropLast(6)) : commit
    }
}

/// The Mac, as far as a bug needs it: OS, chip family, memory. Never the
/// model identifier, serial, name or anything that singles the Mac out.
public struct SystemInfo: Sendable, Equatable {
    public var macOS: String
    public var chip: String
    public var memoryGB: Int

    public init(macOS: String, chip: String, memoryGB: Int) {
        self.macOS = macOS
        self.chip = chip
        self.memoryGB = memoryGB
    }

    public static func current() -> SystemInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        let gb = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return SystemInfo(macOS: macOS, chip: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon", memoryGB: gb)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
