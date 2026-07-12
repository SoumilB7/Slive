import Foundation

/// One locally trained WhisperKit model installed by the Python training pipeline.
struct CustomWhisperModel: Identifiable, Decodable, Equatable {
    let id: String
    let displayName: String
    let baseModel: String
    let modelFolder: URL
    let tokenizerFolder: URL

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case baseModel = "base_model"
        case modelFolder = "model_folder"
        case tokenizerFolder = "tokenizer_folder"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        baseModel = try values.decode(String.self, forKey: .baseModel)
        let model = try values.decode(String.self, forKey: .modelFolder)
        let tokenizer = try values.decode(String.self, forKey: .tokenizerFolder)
        guard let manifest = decoder.userInfo[.customModelManifestURL] as? URL else {
            throw DecodingError.dataCorruptedError(
                forKey: .modelFolder, in: values, debugDescription: "Manifest URL missing")
        }
        let root = manifest.deletingLastPathComponent()
        modelFolder = root.appendingPathComponent(model, isDirectory: true)
        tokenizerFolder = root.appendingPathComponent(tokenizer, isDirectory: true)
    }
}

private extension CodingUserInfoKey {
    static let customModelManifestURL = CodingUserInfoKey(
        rawValue: "com.slive.custom-model-manifest-url")!
}

enum CustomWhisperModelRegistry {
    static var root: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Slive/Models/Custom", isDirectory: true)
    }

    static func load() -> [CustomWhisperModel] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            let manifest = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest) else { return nil }
            let decoder = JSONDecoder()
            decoder.userInfo[.customModelManifestURL] = manifest
            guard let model = try? decoder.decode(CustomWhisperModel.self, from: data),
                  FileManager.default.fileExists(
                    atPath: model.modelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path),
                  FileManager.default.fileExists(
                    atPath: model.modelFolder.appendingPathComponent("TextDecoder.mlmodelc").path)
            else { return nil }
            return model
        }
        .sorted { $0.id > $1.id } // timestamped balenced-ft ids: newest first
    }
}
