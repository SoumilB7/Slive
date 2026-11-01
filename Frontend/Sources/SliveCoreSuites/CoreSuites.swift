import SliveTestKit

/// The suites that test SliveCore and SliveReport alone — no app, no models.
/// `SliveSelfTest` runs just these (a fast build: no WhisperKit); the app's
/// `Slive --self-test` runs them first, then its own (`AllSuites`).
///
/// Adding a suite here = one file in `Suites/` (exposing `static let suite`,
/// touching only SliveCore / SliveReport) plus one line below. A suite that
/// needs an app type belongs in `Sources/Slive/SelfTest/Suites/` instead.
@MainActor
public enum CoreSuites {
    public static let all: [TestSuite] = [
        HotkeyModelTests.suite,
        SpeedTierTests.suite,
        SliveErrorTests.suite,
        VocabularyCorrectorTests.suite,
        DictationQueueTests.suite,
        TranscriptDiffTests.suite,
        ProblemReportTests.suite,
    ]
}
