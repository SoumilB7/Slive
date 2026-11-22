import SliveTestKit

/// The runner itself: a run that checks nothing must not pass.
@MainActor
enum TestRunnerTests {
    static let suite = TestSuite(name: "Test runner") { t in
        print("[Test runner]")
        let names = ["Settings render", "Dictation modes", "Paste focus"]
        t.equal(SelfTestRunner.select(names, only: nil), [0, 1, 2], "no --only: every suite")
        t.equal(SelfTestRunner.select(names, only: "DICTATION"), [1], "--only matches case-insensitively")
        t.equal(SelfTestRunner.select(names, only: "nosuchsuite"), [], "--only typo selects nothing")
        t.equal(SelfTestRunner.select(names, only: ""), [], "--only with no value selects nothing, not everything")
        t.equal(SelfTestRunner.verdict(passed: 0, failed: 0), 1, "zero checks run: exit 1")
        t.equal(SelfTestRunner.verdict(passed: 3, failed: 0), 0, "all passed: exit 0")
        t.equal(SelfTestRunner.verdict(passed: 3, failed: 1), 1, "any failure: exit 1")
    }
}
