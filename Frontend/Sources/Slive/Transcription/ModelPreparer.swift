import Foundation

/// `Slive --prepare-models` — run by `build.sh` right after installing, BEFORE
/// launching the app.
///
/// macOS keys its compiled Neural Engine programs to the exact app binary:
/// the first launch of any new build recompiles the Whisper encoder (~80s
/// measured) and decoder (~9s), and nothing can transcribe until that
/// finishes — the "first dictations don't run after a rebuild" bug. Running
/// the installed binary once headless moves that compile into the build
/// step, so the app opens with its models already compiled (ready in ~3s)
/// and warmed with real speech.
///
/// Exits 1 when a model failed to load, so the installer can say so instead
/// of "Model ready". Each model gets `budgetSeconds`: a Neural Engine compile
/// that's still going by then finishes in the app (behind its CPU copy).
@MainActor
enum ModelPreparer {
    static let budgetSeconds: UInt64 = 300

    static func run() async -> Int32 {
        TranscriptionModel.benchSuppressesAutoWarm = true   // warm below, awaited
        let settings = Settings.shared
        var models = [settings.whisperModel]
        if ((settings.streamHoldOn && settings.streamHotkey != nil)
            || (settings.streamToggleOn && settings.streamToggleHotkey != nil)),
           !models.contains(settings.continuousModel) {
            models.append(settings.continuousModel)
        }
        let whisper = TranscriptionModel.shared
        var failed = false
        for model in models {
            guard whisper.isDownloaded(model) else {
                print("  \(model): not downloaded — skipped"); continue
            }
            let t0 = Date()
            let loaded = (try? await withTimeout(seconds: budgetSeconds, what: "prepare") {
                await whisper.ensureLoaded(model)
            }) ?? false
            guard loaded || whisper.isReady(model) else {
                failed = true
                if case .failed(let reason) = whisper.status(for: model) {
                    print("  \(model): ✗ failed to load — \(reason)")
                } else {
                    print("  \(model): ✗ not ready after \(budgetSeconds)s")
                }
                continue
            }
            guard loaded else {
                print("  \(model): ready on CPU — Neural Engine compile finishes in the app")
                continue
            }
            let loadSeconds = Date().timeIntervalSince(t0)
            if let speech = TranscriptionModel.warmUpAudio {
                _ = await whisper.transcribeSamples(speech, model: model)
            }
            print(String(format: "  %@: compiled + loaded in %.0fs, warmed in %.1fs",
                         model, loadSeconds, Date().timeIntervalSince(t0) - loadSeconds))
        }
        return failed ? 1 : 0
    }
}
