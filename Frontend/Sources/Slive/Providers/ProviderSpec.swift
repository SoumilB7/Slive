import Foundation

/// An LLM provider Slive's assistant mode can talk to. The raw value is the
/// persisted id (UserDefaults, `AssistantConfig.models` keys, Keychain
/// accounts) and must never change; everything else about a provider lives in
/// its `ProviderSpec` in `ProviderCatalog`.
enum AssistantProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case gemini
    case openaiCompatible
    case local
    /// On-device WhisperKit transcription — a ground-truth-only "provider"
    /// (it can't chat, so it never appears in the Assistant picker and is
    /// never sent to the backend).
    case whisper

    var id: String { rawValue }
}

/// What a provider can do / needs. Views and clients ask these instead of
/// naming providers, so a new provider only has to declare its own.
enum Capability: Hashable {
    /// The Assistant hotkey can talk to it (`/assistant`).
    case chat
    /// Accepts audio — offered as a single ground-truth labeler.
    case audioTranscribe
    /// Its live model list is fetched through the backend (`/assistant/models`).
    case listModels
    /// Takes an API key (Keychain account `provider.<raw>`).
    case needsKey
    /// Needs a custom base URL (shared by Assistant and ground truth).
    case needsBaseURL
    /// Runs a model downloaded to the Hugging Face cache, picked from the
    /// cache rather than typed/fetched (the HF token is only for downloading).
    case local
    /// Runs entirely on this Mac — no key, nothing leaves the machine.
    case onDevice
}

/// Everything Slive knows about one provider.
struct ProviderSpec {
    let id: AssistantProvider
    /// String sent to the backend — the `provider` value the Python server
    /// understands. Not always the raw value (`openaiCompatible` → `openai_compatible`).
    let wire: String
    let displayName: String
    /// Assistant model when none is chosen ("" = must be picked).
    var defaultModel = ""
    /// Ground-truth model preset when the provider is picked as the labeler
    /// (nil = none; the field starts empty).
    var groundTruthDefaultModel: String? = nil
    /// Position in the ground-truth picker: lower first, ties keep catalog order.
    var groundTruthRank = 1
    /// Placeholder in the API key field.
    var keyHint = ""
    /// SF Symbol for the Models page row (brand-free glyphs).
    let icon: String
    /// Where to get a key ("Get a key" link), if there's one place.
    var keyURL: URL? = nil
    let capabilities: Set<Capability>

    func has(_ capability: Capability) -> Bool { capabilities.contains(capability) }
}

/// The one list of providers. Adding a provider: a case on `AssistantProvider`
/// and its spec in `make` (the compiler insists on both) — plus the Python
/// provider of the same `wire` name.
enum ProviderCatalog {
    /// Every provider, in `AssistantProvider` declaration order — the order
    /// every picker and list shows them in.
    static let all: [ProviderSpec] = AssistantProvider.allCases.map(make)

    private static let byID: [AssistantProvider: ProviderSpec] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func spec(for provider: AssistantProvider) -> ProviderSpec {
        byID[provider] ?? make(provider)
    }

    /// Providers with `capability`, in catalog order.
    static func providers(with capability: Capability) -> [AssistantProvider] {
        all.filter { $0.has(capability) }.map(\.id)
    }

    /// The consensus ground-truth recipe (gpt-transcribe + whisper-1) runs on
    /// this provider's key, whatever single provider is selected.
    static let consensusKeyProvider: AssistantProvider = .openai

    /// Providers the Assistant hotkey can talk to — Whisper only transcribes,
    /// so it exists solely for the ground-truth picker.
    static var assistantChoices: [AssistantProvider] { providers(with: .chat) }

    /// Providers connected with a key — the Models page's CLOUD rows (and the
    /// sidebar's "n connected" count).
    static var keyed: [AssistantProvider] { providers(with: .needsKey) }

    /// The single-labeler choices of the ground-truth picker.
    static var groundTruthChoices: [AssistantProvider] {
        all.enumerated()
            .filter { $0.element.has(.audioTranscribe) }
            .sorted { ($0.element.groundTruthRank, $0.offset) < ($1.element.groundTruthRank, $1.offset) }
            .map(\.element.id)
    }

    private static func make(_ p: AssistantProvider) -> ProviderSpec {
        switch p {
        case .anthropic:
            return ProviderSpec(
                id: p, wire: "anthropic", displayName: "Anthropic (Claude)",
                defaultModel: "claude-sonnet-5",
                keyHint: "sk-ant-…", icon: "a.circle.fill",
                keyURL: URL(string: "https://console.anthropic.com/settings/keys"),
                capabilities: [.chat, .listModels, .needsKey])
        case .openai:
            // gpt-4o-audio-preview was superseded — `gpt-audio` is the GA audio
            // chat model; accounts without the legacy preview 404 on it.
            return ProviderSpec(
                id: p, wire: "openai", displayName: "OpenAI",
                defaultModel: "gpt-4o", groundTruthDefaultModel: "gpt-audio",
                keyHint: "sk-…", icon: "o.circle.fill",
                keyURL: URL(string: "https://platform.openai.com/api-keys"),
                capabilities: [.chat, .audioTranscribe, .listModels, .needsKey])
        case .gemini:
            return ProviderSpec(
                id: p, wire: "gemini", displayName: "Google Gemini",
                defaultModel: "gemini-2.5-flash", groundTruthDefaultModel: "gemini-2.5-flash",
                groundTruthRank: 0,
                keyHint: "AIza…", icon: "g.circle.fill",
                keyURL: URL(string: "https://aistudio.google.com/apikey"),
                capabilities: [.chat, .audioTranscribe, .listModels, .needsKey])
        case .openaiCompatible:
            return ProviderSpec(
                id: p, wire: "openai_compatible", displayName: "OpenAI-compatible",
                keyHint: "API key", icon: "chevron.left.forwardslash.chevron.right",
                capabilities: [.chat, .audioTranscribe, .listModels, .needsKey, .needsBaseURL])
        case .local:
            // Local qualifies for ground truth via audio-capable downloads
            // (e.g. Gemma 3n).
            return ProviderSpec(
                id: p, wire: "local", displayName: "Local (on-device)",
                icon: "desktopcomputer",
                capabilities: [.chat, .audioTranscribe, .local, .onDevice])
        case .whisper:
            // Never sent — handled fully in-app. Defaults to the accuracy judge.
            return ProviderSpec(
                id: p, wire: "whisper", displayName: "Whisper (on-device)",
                defaultModel: "large-v3", groundTruthDefaultModel: "large-v3",
                icon: "waveform",
                capabilities: [.audioTranscribe, .onDevice])
        }
    }
}

extension AssistantProvider {
    var spec: ProviderSpec { ProviderCatalog.spec(for: self) }

    func has(_ capability: Capability) -> Bool { spec.has(capability) }

    /// String sent to the backend.
    var wire: String { spec.wire }

    var displayName: String { spec.displayName }

    var defaultModel: String { spec.defaultModel }

    /// Default audio-capable model when picked as the ground-truth labeler.
    var groundTruthDefaultModel: String { spec.groundTruthDefaultModel ?? "" }

    /// Only the OpenAI-compatible provider needs a custom base URL.
    var needsBaseURL: Bool { has(.needsBaseURL) }

    /// Local runs a downloaded model on-device — it takes no API key (the model
    /// is loaded straight from the HF cache; the token is only for downloading).
    var needsAPIKey: Bool { has(.needsKey) }

    /// True when the model is a downloaded local one, chosen from the cache
    /// rather than typed/fetched from a provider's list.
    var isLocal: Bool { has(.local) }

    /// Runs on this Mac (Local, Whisper): shown with the on-device pill.
    var runsOnDevice: Bool { has(.onDevice) }

    /// Where to find the API key hint / signup.
    var keyHint: String { spec.keyHint }

    /// Providers the Assistant hotkey can talk to.
    static var assistantChoices: [AssistantProvider] { ProviderCatalog.assistantChoices }

    /// Keychain account name for this provider's API key.
    var keychainAccount: String { CredentialStore.account(for: self) }
}
