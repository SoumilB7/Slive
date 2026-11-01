import AppKit

enum DebugHooks {
    /// Test hooks for the problem reporter (like SLIVE_TEST_ANE_HANG):
    /// freeze the main thread N seconds, crash, or report a fake failure,
    /// 6 s after launch.
    @MainActor static func install() {
        let env = ProcessInfo.processInfo.environment
        if let freeze = env["SLIVE_TEST_FREEZE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { Thread.sleep(forTimeInterval: freeze) }
        }
        if env["SLIVE_TEST_CRASH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { fatalError("SLIVE_TEST_CRASH") }
        }
        if env["SLIVE_TEST_FAILURE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                FailureReporter.shared.report("speech model", "The speech model failed to load.",
                                              error: NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [
                                                  NSLocalizedDescriptionKey: "The file at \(NSHomeDirectory())/Library/x.mlmodelc couldn’t be opened."]),
                                              detail: "model test")
            }
        }
    }
}
