import Foundation
import WhisperKit

/// WhisperKit models on disk: the bundled tiny (ships in the app; offline),
/// installed fine-tunes, and downloads in the basket — each model in its own
/// `openai_whisper-<variant>` folder plus the tokenizer the load resolves
/// locally.
@MainActor
final class WhisperStorage: ModelStorage {
    let basket: ModelBasket
    private let resources: URL?
    /// Installed fine-tunes; `refresh` re-reads them from disk first.
    private let customModels: (_ refresh: Bool) -> [CustomWhisperModel]

    init(basket: ModelBasket, resources: URL? = Bundle.main.resourceURL,
         customModels: @escaping (_ refresh: Bool) -> [CustomWhisperModel]) {
        self.basket = basket
        self.resources = resources
        self.customModels = customModels
    }

    var modelsRoot: URL { basket.url.appendingPathComponent("models/argmaxinc/whisperkit-coreml") }

    func customModel(_ id: String) -> CustomWhisperModel? {
        customModels(false).first { $0.id == id }
    }

    // MARK: - Bundled model (ships in the app; offline)

    func bundledFolder(_ model: String) -> URL? {
        guard let resources else { return nil }
        let folder = resources.appendingPathComponent("BundledModels/openai_whisper-\(model)")
        let ok = FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
        return ok ? folder : nil
    }
    var bundledTokenizerRoot: URL? {
        resources?.appendingPathComponent("BundledTokenizers")
    }

    // MARK: - ModelStorage

    func hasFiles(_ model: String) -> Bool {
        if customModels(true).contains(where: { $0.id == model }) { return true }
        if bundledFolder(model) != nil { return true }
        guard let folder = downloadedFolder(model) else { return false }
        // Downloads made before the completion marker existed count when
        // every model file and the tokenizer are on disk.
        return ModelBasket.isStamped(folder) || isStructurallyComplete(folder)
    }

    func isInstalledLocally(_ model: String) -> Bool { customModel(model) != nil }

    func fetch(_ model: String, progress: DownloadProgress) async throws -> URL? {
        let basket = self.basket.url
        let folder = try await WhisperKit.download(variant: model, downloadBase: basket) {
            progress.report($0.fractionCompleted)
        }
        // The tokenizer too: the load resolves it locally, so a
        // downloaded model then loads with no network at all.
        progress.alive()
        if let variant = Self.whisperVariant(configAt: folder) {
            _ = try await loadTokenizer(for: variant, tokenizerFolder: basket)
        }
        return folder
    }

    func remove(_ model: String) {
        guard customModel(model) == nil, let folder = downloadedFolder(model) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Folders

    /// `model`'s folder in the basket, matched by exact name.
    func downloadedFolder(_ model: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: modelsRoot.path)) ?? []
        return Self.folderName(for: model, among: names).map { modelsRoot.appendingPathComponent($0) }
    }

    /// WhisperKit names a variant's folder `openai_whisper-<variant>` (or
    /// `<org>_<variant>` for others). A suffix match once tied "large-v3" to
    /// distil-large-v3's folder too — so a partial one could pass for the
    /// other, and Re-download deleted both.
    nonisolated static func folderName(for model: String, among names: [String]) -> String? {
        if names.contains("openai_whisper-\(model)") { return "openai_whisper-\(model)" }
        if names.contains(model) { return model }
        let others = names.filter { $0.hasSuffix("_\(model)") }
        return others.count == 1 ? others[0] : nil
    }

    /// The three Core ML models WhisperKit can't load without.
    nonisolated static let requiredModels = ["AudioEncoder", "TextDecoder", "MelSpectrogram"]

    /// Every model file, config.json (in Hugging Face's path order it comes
    /// after the .mlmodelc folders, so it's among the last files fetched) and
    /// the tokenizer it names, which the load resolves locally.
    func isStructurallyComplete(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard Self.requiredModels.allSatisfy({
            fm.fileExists(atPath: folder.appendingPathComponent("\($0).mlmodelc/coremldata.bin").path)
        }), let variant = Self.whisperVariant(configAt: folder) else { return false }
        return fm.fileExists(atPath: tokenizerFile(variant).path)
    }

    /// Where WhisperKit looks for `variant`'s tokenizer under the basket.
    func tokenizerFile(_ variant: ModelVariant) -> URL {
        basket.url.appendingPathComponent("models/openai/whisper-\(variant.description)/tokenizer.json")
    }

    /// The variant (→ tokenizer) WhisperKit will detect for the model in
    /// `folder`, read from its config.json — nil when there is none.
    nonisolated static func whisperVariant(configAt folder: URL) -> ModelVariant? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vocab = json["vocab_size"] as? Int, let width = json["d_model"] as? Int else { return nil }
        return whisperVariant(vocabSize: vocab, dModel: width)
    }

    /// WhisperKit's own detection (logits size × encoder width), mirrored so
    /// the download can fetch the tokenizer the load will ask for.
    nonisolated static func whisperVariant(vocabSize: Int, dModel: Int) -> ModelVariant {
        switch (vocabSize, dModel) {
        case (51866, _): return .largev3
        case (51865, 384): return .tiny
        case (51865, 768): return .small
        case (51865, 1024): return .medium
        case (51865, 1280): return .largev2
        case (51864, 384): return .tinyEn
        case (51864, 768): return .smallEn
        case (51864, 1024): return .mediumEn
        case (51864, _): return .baseEn
        default: return .base
        }
    }
}
