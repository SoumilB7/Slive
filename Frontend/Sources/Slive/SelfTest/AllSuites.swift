import SliveTestKit

/// The app-bound self-test suites, in run order (`Slive --self-test` runs
/// `CoreSuites.all` first, then these). Adding a suite = one file in
/// `Suites/` (exposing `static let suite`) plus one line here — or, if it
/// touches only SliveCore / SliveReport, the same in SliveCoreSuites.
@MainActor
enum AllSuites {
    static let all: [TestSuite] = [
        HotkeyMatchingTests.suite,
        ProviderTests.suite,
        CatalogAndStorageTests.suite,
        SpeedTierMachineTests.suite,
        VocabHintTests.suite,
        BackendErrorTests.suite,
        LocalServerTests.suite,
        DefaultShortcutTests.suite,
        SettingsStoreTests.suite,
        HotkeyActionTests.suite,
        SilenceTrimTests.suite,
        TextHygieneTests.suite,
        SpeechPipelineTests.suite,
        PasteFocusTests.suite,
        PacingTests.suite,
        WpmTests.suite,
        OverlayMetricsTests.suite,
        SampleFormatTests.suite,
        LabelRunTests.suite,
        StitchTests.suite,
        ParakeetWindowTests.suite,
        LiveTypingTests.suite,
        TextSinkTests.suite,
        TranscriptDiffStylingTests.suite,
        DictationRoutingTests.suite,
        CaptureAndHistoryTests.suite,
        CaptureConsumerTests.suite,
        ModelLifecycleTests.suite,
        TranscriptionPartsTests.suite,
        SettingsUITests.suite,
        OverlayStateTests.suite,
        ModelResidencyTests.suite,
        SessionCoordinatorTests.suite,
        ChatSessionTests.suite,
        DictationModeTests.suite,
        SelfTestLayoutTests.suite,
        SettingsRenderTests.suite,
    ]
}
