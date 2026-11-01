import FluidAudio
import Foundation

/// Which speech engine runs a model id, resolved through `ModelCatalog`.
/// Every id Slive stored before Parakeet is a WhisperKit variant ("tiny.en",
/// "large-v3-v20240930_626MB", custom fine-tunes) and isn't in the catalog
/// as anything else; Parakeet ids carry a `parakeet-` prefix, so the split
/// is unambiguous and old settings keep meaning exactly what they meant.
enum SpeechEngine: Equatable {
    case whisper
    case parakeet(ParakeetModel)

    /// The engine alone, without its model — what a catalog entry records.
    enum Kind {
        case whisper
        case parakeet
    }

    var kind: Kind {
        switch self {
        case .whisper: return .whisper
        case .parakeet: return .parakeet
        }
    }

    static func of(_ modelID: String) -> SpeechEngine {
        switch ModelCatalog.engine(of: modelID) {
        case .whisper: return .whisper
        case .parakeet: return ParakeetModel(rawValue: modelID).map(SpeechEngine.parakeet) ?? .whisper
        }
    }
}

/// The Parakeet models Slive offers (FluidAudio's Core ML ports of NVIDIA's
/// Parakeet TDT 0.6B, run on the Neural Engine).
///
/// Measured on Soumil's 120 labelled clips (Sep 27, 2026): decodes in
/// ~51–54ms median vs Whisper large-v3-turbo's ~935ms; normalised WER
/// Ultra 7.3% / v2 8.1% vs Whisper 6.1% (misses concentrate on names and
/// jargon).
enum ParakeetModel: String, CaseIterable, Identifiable {
    /// moondream's post-training of Parakeet v3 — FluidAudio's recommended
    /// model: the most accurate Parakeet, 25 languages.
    case ultra = "parakeet-ultra"
    /// The original English-only Parakeet TDT v2.
    case v2 = "parakeet-v2"

    var id: String { rawValue }

    var asrVersion: AsrModelVersion {
        switch self {
        case .ultra: return .ultra
        case .v2: return .v2
        }
    }

    var displayName: String {
        switch self {
        case .ultra: return "Parakeet – Ultra"
        case .v2: return "Parakeet – v2"
        }
    }
}
