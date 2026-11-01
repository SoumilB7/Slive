import Foundation

/// One named group of checks. Suites print their own `[Section]` header and
/// record results through `Checks`.
public struct TestSuite {
    public let name: String
    public let run: @MainActor (inout Checks) -> Void

    public init(name: String, run: @escaping @MainActor (inout Checks) -> Void) {
        self.name = name
        self.run = run
    }
}

/// Pass/fail counters plus the two assertion helpers every suite uses.
public struct Checks {
    public private(set) var passed = 0
    public private(set) var failed = 0

    public init() {}

    public mutating func check(_ condition: Bool, _ name: String, _ detail: String = "") {
        if condition {
            passed += 1
            print("  ✅ \(name)")
        } else {
            failed += 1
            print("  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    public mutating func equal<T: Equatable>(_ a: T, _ b: T, _ name: String) {
        check(a == b, name, "got \(a), expected \(b)")
    }
}

/// Runs suites in order; `--only <substring>` keeps suites whose name
/// contains it (case-insensitive).
@MainActor
public enum SelfTestRunner {
    public static func runAndExit(_ suites: [TestSuite], title: String = "Slive self-test") -> Never {
        var selected = suites
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--only"), i + 1 < args.count {
            let needle = args[i + 1].lowercased()
            selected = suites.filter { $0.name.lowercased().contains(needle) }
        }
        print("\(title)\n\(String(repeating: "=", count: title.count))")
        var checks = Checks()
        for suite in selected { suite.run(&checks) }
        print("\(String(repeating: "=", count: title.count))\n\(checks.passed) passed, \(checks.failed) failed")
        exit(checks.failed == 0 ? 0 : 1)
    }
}
