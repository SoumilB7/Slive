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
        let args = CommandLine.arguments
        let only = args.firstIndex(of: "--only").map { $0 + 1 < args.count ? args[$0 + 1] : "" }
        let selected = select(suites.map(\.name), only: only).map { suites[$0] }
        print("\(title)\n\(String(repeating: "=", count: title.count))")
        var checks = Checks()
        for suite in selected { suite.run(&checks) }
        print("\(String(repeating: "=", count: title.count))\n\(checks.passed) passed, \(checks.failed) failed")
        exit(verdict(passed: checks.passed, failed: checks.failed))
    }

    /// Indices of the suites `--only` keeps (all when it's absent). A
    /// missing value selects nothing rather than everything, so a typo can't
    /// silently run a different set.
    public static func select(_ names: [String], only: String?) -> [Int] {
        guard let only else { return Array(names.indices) }
        let needle = only.lowercased()
        guard !needle.isEmpty else { return [] }
        return names.indices.filter { names[$0].lowercased().contains(needle) }
    }

    /// Exit status: a run that checked nothing fails — a misspelled `--only`
    /// used to print "0 passed, 0 failed" and exit 0, passing while testing
    /// nothing.
    public static func verdict(passed: Int, failed: Int) -> Int32 {
        if passed + failed == 0 { print("No checks ran. Check the --only filter."); return 1 }
        return failed == 0 ? 0 : 1
    }
}
