import Foundation

/// Where a model can be picked. An engine without live streaming would leave
/// out `.continuous`; the ground-truth judge decodes local Whisper only.
enum ModelUse: CaseIterable {
    case dictation
    case continuous
    case groundTruth
}

/// One speech model Slive offers. `id` is the EXACT string persisted in
/// UserDefaults (`whisperModel`, `continuousModel`, `groundTruthModel`) —
/// never rename one, or saved picks silently stop resolving.
struct ModelDescriptor: Identifiable, Equatable {
    let id: String
    let engine: SpeechEngine.Kind
    /// Picker title, e.g. "Whisper – large-v3 turbo".
    let label: String
    /// What it's good for, e.g. "Recommended".
    let note: String
    /// Download size, e.g. "600 MB" (nil for installed fine-tunes).
    var size: String?
    var uses: Set<ModelUse> = Set(ModelUse.allCases)
    /// Ships inside the app bundle — dictates offline on first launch.
    var bundled = false

    /// The picker's detail line: "Recommended · 600 MB".
    var detail: String { size.map { "\(note) · \($0)" } ?? note }
}

/// Every speech model Slive offers, built from one list per engine. The
/// picker, the status lines and the defaults read it; engine routing
/// (`SpeechEngine.of`) resolves ids through it.
///
/// Ids not in the catalog are Whisper: every id Slive stored before Parakeet
/// existed is a WhisperKit variant or a custom fine-tune, so old settings
/// keep meaning exactly what they meant.
enum ModelCatalog {
    /// One list per engine, in picker order (a divider between lists).
    static let lists: [[ModelDescriptor]] = [WhisperCatalog.models, ParakeetCatalog.models]

    static let all: [ModelDescriptor] = lists.flatMap { $0 }

    /// The engine every unknown id belongs to (legacy bare ids, fine-tunes).
    static let fallbackEngine: SpeechEngine.Kind = .whisper

    // MARK: Defaults (persisted strings — must stay resolvable)

    /// Fresh-install dictation model: the bundled tiny, so the first launch
    /// works instantly and fully offline.
    static let defaultDictation = WhisperCatalog.tiny
    /// Fresh-install continuous model.
    static let defaultContinuous = ParakeetModel.ultra.rawValue
    /// The ground-truth judge's default when Whisper is its provider.
    static let defaultGroundTruth = WhisperCatalog.large
    /// "Balanced": the accurate model worth downloading over tiny/base — the
    /// suggestion card's target and the benches' default.
    static let balanced = WhisperCatalog.turbo

    // MARK: Lookup

    static func descriptor(_ id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }

    static func engine(of id: String) -> SpeechEngine.Kind {
        descriptor(id)?.engine ?? fallbackEngine
    }

    /// The picker's sections for `use`: one per engine, empty ones dropped.
    static func sections(for use: ModelUse) -> [[ModelDescriptor]] {
        lists.map { $0.filter { $0.uses.contains(use) } }.filter { !$0.isEmpty }
    }

    /// Ids of `engine`'s catalog models, in order.
    static func ids(of engine: SpeechEngine.Kind) -> [String] {
        all.filter { $0.engine == engine }.map(\.id)
    }

    /// An installed fine-tune as a catalog entry (Whisper; offered everywhere).
    static func descriptor(for custom: CustomWhisperModel) -> ModelDescriptor {
        ModelDescriptor(id: custom.id, engine: .whisper, label: custom.displayName,
                        note: "Fine-tuned \(custom.baseModel) · \(custom.id)")
    }

    /// `id` as a catalog model offered for `use` (nil = any use), else as an
    /// installed fine-tune; nil when it's neither (a stale or hand-typed id).
    static func resolve(_ id: String, for use: ModelUse? = nil,
                        custom: [CustomWhisperModel]) -> ModelDescriptor? {
        if let d = descriptor(id), use.map(d.uses.contains) ?? true { return d }
        return custom.first { $0.id == id }.map(descriptor(for:))
    }
}
