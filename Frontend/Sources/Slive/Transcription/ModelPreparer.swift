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
@MainActor
enum ModelPreparer {
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
        for model in models {
            guard whisper.isDownloaded(model) else {
                print("  \(model): not downloaded — skipped"); continue
            }
            let t0 = Date()
            guard await whisper.ensureLoaded(model) else {
                print("  \(model): ✗ failed to load"); continue
            }
            let loaded = Date().timeIntervalSince(t0)
            if let speech = TranscriptionModel.warmUpAudio {
                _ = await whisper.transcribeSamples(speech, model: model)
            }
            print(String(format: "  %@: compiled + loaded in %.0fs, warmed in %.1fs",
                         model, loaded, Date().timeIntervalSince(t0) - loaded))
        }
        return 0
    }
}
