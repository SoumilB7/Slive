import Foundation
import WhisperKit

private struct TimeoutError: Error {}

/// Run `operation`, failing with `TimeoutError` if it doesn't finish in time.
private func withTimeout<T>(seconds: UInt64,
                            _ operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw TimeoutError()
        }
        guard let result = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return result
    }
}

/// Manages the on-device (WhisperKit / Neural Engine) transcription model:
/// checks whether it's downloaded, downloads it in-app with progress, loads it,
/// and transcribes. Observable so Settings can show status and a Download button.
///
/// The first load of a model compiles it for the Neural Engine ("Specializing"),
/// which is slow *once* — surfaced here as `.preparing` instead of a silent hang.
@MainActor
final class TranscriptionModel: ObservableObject {
    static let shared = TranscriptionModel()
    private init() {}

    enum Status: Equatable {
        case notDownloaded
        case downloading(Double)   // 0…1
        case preparing             // loading + Neural-Engine specialization
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .notDownloaded
    /// The model these statuses refer to.
    @Published private(set) var model: String = ""

    private var pipe: WhisperKit?
    private var loadedModel: String?

    /// WhisperKit's default download location (HubApi): ~/Documents/huggingface/…
    private var modelsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
    }

    // MARK: - Bundled model (ships in the app; no download, fully offline)

    /// Folder of a model shipped inside the app bundle, if present.
    private func bundledModelFolder(_ model: String) -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let folder = res.appendingPathComponent("BundledModels/openai_whisper-\(model)")
        let ok = FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
        return ok ? folder : nil
    }

    /// Root the bundled tokenizer lives under (HubApi layout: <root>/models/openai/…).
    private var bundledTokenizerRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("BundledTokenizers")
    }

    /// True if `model` is available without a download — bundled OR on disk.
    func isDownloaded(_ model: String) -> Bool {
        if bundledModelFolder(model) != nil { return true }
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: modelsRoot, includingPropertiesForKeys: nil) else { return false }
        return subs.contains { folder in
            folder.lastPathComponent.hasSuffix(model)
                && FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
        }
    }

    /// Delete a downloaded model folder so a fresh download can recover a stale
    /// or partial one. (Bundled models are untouched.)
    func removeDownloaded(_ model: String) {
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: modelsRoot, includingPropertiesForKeys: nil) else { return }
        for folder in subs where folder.lastPathComponent.hasSuffix(model) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Reflect the on-disk state for `model` in `status` (no download). Call when
    /// the picker changes or Settings appears.
    func refresh(for model: String) {
        self.model = model
        if loadedModel == model, pipe != nil { status = .ready; return }
        status = isDownloaded(model) ? .ready : .notDownloaded
    }

    /// If a model is already downloaded, load it into the Neural Engine in the
    /// background so the first dictation is instant. Never downloads.
    func preloadIfDownloaded(_ model: String) {
        self.model = model
        guard loadedModel != model || pipe == nil else { status = .ready; return }
        guard isDownloaded(model) else { status = .notDownloaded; return }
        Task { await self.load(model) }
    }

    /// Download (if needed) then load `model`, reporting progress. Idempotent.
    func download(_ model: String) async {
        self.model = model
        if loadedModel == model, pipe != nil { status = .ready; return }
        if !isDownloaded(model) {
            status = .downloading(0)
            do {
                _ = try await WhisperKit.download(variant: model) { [weak self] progress in
                    Task { @MainActor in self?.status = .downloading(progress.fractionCompleted) }
                }
            } catch {
                status = .failed("Download failed: \(error.localizedDescription)")
                return
            }
        }
        await load(model)
    }

    /// Load an already-downloaded (or bundled) model. Compiles for the ANE the
    /// first time. Bounded by a timeout so it can never hang on "Preparing"
    /// forever — on timeout it fails with a message the user can act on.
    private func load(_ model: String) async {
        self.model = model
        status = .preparing

        let config: WhisperKitConfig
        if let bundled = bundledModelFolder(model) {
            // Fully offline: load the app-bundled model + tokenizer, no network.
            config = WhisperKitConfig(model: model,
                                      modelFolder: bundled.path,
                                      tokenizerFolder: bundledTokenizerRoot,
                                      load: true,
                                      download: false)
        } else {
            config = WhisperKitConfig(model: model, load: true, download: true)
        }

        // Large models can take a couple of minutes to specialize the first time;
        // bundled/tiny is seconds. Give a generous ceiling, then bail.
        let timeout: UInt64 = bundledModelFolder(model) != nil ? 60 : 240
        do {
            let p = try await withTimeout(seconds: timeout) { try await WhisperKit(config) }
            pipe = p
            loadedModel = model
            status = .ready
            NSLog("Slive: WhisperKit ready (\(model)).")
        } catch is TimeoutError {
            status = .failed("Timed out preparing this model. Try Re-download, or pick a smaller model.")
            NSLog("Slive: WhisperKit load timed out for \(model)")
        } catch {
            status = .failed(error.localizedDescription)
            NSLog("Slive: WhisperKit load failed — \(error)")
        }
    }

    /// Delete the on-disk copy of `model` and download it fresh (recovers a
    /// stale/partial download). No-op look for bundled models.
    func redownload(_ model: String) async {
        pipe = nil
        loadedModel = nil
        removeDownloaded(model)
        await download(model)
    }

    /// Transcribe `url` if the model is ready (loading it on demand when it's
    /// already downloaded). Returns nil when the model isn't available yet — the
    /// caller should tell the user to download it, NOT hang on a spinner.
    func transcribe(_ url: URL, model: String) async -> String? {
        if loadedModel != model || pipe == nil {
            guard isDownloaded(model) else { refresh(for: model); return nil }
            await load(model)
        }
        guard let pipe, case .ready = status else { return nil }
        do {
            let results = try await pipe.transcribe(
                audioPath: url.path,
                decodeOptions: DecodingOptions(language: "en")
            )
            return results
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("Slive: transcription failed — \(error)")
            return nil
        }
    }
}
