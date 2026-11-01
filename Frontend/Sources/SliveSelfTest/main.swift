import SliveCoreSuites
import SliveTestKit

// `SliveSelfTest`: the SliveCore + SliveReport suites on their own — builds
// without WhisperKit or the app, so pure-logic edits check in seconds.
// `--only <name>` works as in `Slive --self-test` (which runs these too).
MainActor.assumeIsolated {
    SelfTestRunner.runAndExit(CoreSuites.all, title: "SliveCore self-test")
}
