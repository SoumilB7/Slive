/// The Parakeet models Slive offers (FluidAudio, Neural Engine): one entry
/// per `ParakeetModel` case. Dictation and continuous (its own live loop);
/// the ground-truth judge stays Whisper.
enum ParakeetCatalog {
    static let models: [ModelDescriptor] = ParakeetModel.allCases.map(\.descriptor)
}

extension ParakeetModel {
    var descriptor: ModelDescriptor {
        let uses: Set<ModelUse> = [.dictation, .continuous]
        switch self {
        case .ultra:
            return ModelDescriptor(id: rawValue, engine: .parakeet, label: displayName,
                                   note: "Fastest · weaker on names", size: "610 MB", uses: uses)
        case .v2:
            return ModelDescriptor(id: rawValue, engine: .parakeet, label: displayName,
                                   note: "English", size: "450 MB", uses: uses)
        }
    }
}
