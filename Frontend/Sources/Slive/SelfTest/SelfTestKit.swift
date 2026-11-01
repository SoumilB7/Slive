import Foundation

/// One named group of checks. Suites print their own `[Section]` header and
/// record results through `Checks`.
struct TestSuite {
    let name: String
    let run: @MainActor (inout Checks) -> Void
}

/// Pass/fail counters plus the two assertion helpers every suite uses.
struct Checks {
    private(set) var passed = 0
    private(set) var failed = 0

    mutating func check(_ condition: Bool, _ name: String, _ detail: String = "") {
        if condition {
            passed += 1
            print("  ✅ \(name)")
        } else {
            failed += 1
            print("  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    mutating func equal<T: Equatable>(_ a: T, _ b: T, _ name: String) {
        check(a == b, name, "got \(a), expected \(b)")
    }
}

/// Runs suites in order; `--only <substring>` keeps suites whose name
/// contains it (case-insensitive).
@MainActor
enum SelfTestRunner {
    static func runAndExit(_ suites: [TestSuite]) -> Never {
        var selected = suites
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--only"), i + 1 < args.count {
            let needle = args[i + 1].lowercased()
            selected = suites.filter { $0.name.lowercased().contains(needle) }
        }
        print("Slive self-test\n===============")
        var checks = Checks()
        for suite in selected { suite.run(&checks) }
        print("===============\n\(checks.passed) passed, \(checks.failed) failed")
        exit(checks.failed == 0 ? 0 : 1)
    }
}
