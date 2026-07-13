import Foundation
import WhisperKit

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

    /// True if `model`'s files are already on disk.
    func isDownloaded(_ model: String) -> Bool {
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: modelsRoot, includingPropertiesForKeys: nil) else { return false }
        return subs.contains { folder in
            folder.lastPathComponent.hasSuffix(model)
                && FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
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

    /// Load an already-downloaded model (compiles for the ANE the first time).
    private func load(_ model: String) async {
        self.model = model
        status = .preparing
        do {
            let config = WhisperKitConfig(model: model, load: true, download: true)
            let p = try await WhisperKit(config)
            pipe = p
            loadedModel = model
            status = .ready
            NSLog("Slive: WhisperKit ready (\(model)).")
        } catch {
            status = .failed(error.localizedDescription)
            NSLog("Slive: WhisperKit load failed — \(error)")
        }
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
