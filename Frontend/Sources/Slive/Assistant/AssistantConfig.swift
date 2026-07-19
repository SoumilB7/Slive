import Foundation

/// An LLM provider Slive's assistant mode can talk to. The `wire` value must
/// match the `provider` strings the Python `/assistant` endpoint understands.
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

    /// String sent to the backend.
    var wire: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        case .gemini: return "gemini"
        case .openaiCompatible: return "openai_compatible"
        case .local: return "local"
        case .whisper: return "whisper"   // never sent — handled fully in-app
        }
    }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openaiCompatible: return "OpenAI-compatible"
        case .local: return "Local (on-device)"
        case .whisper: return "Whisper (on-device)"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.5-flash"
        case .openaiCompatible: return ""
        case .local: return ""
        case .whisper: return "large-v3"   // the accuracy judge
        }
    }

    /// Only the OpenAI-compatible provider needs a custom base URL.
    var needsBaseURL: Bool { self == .openaiCompatible }

    /// Local runs a downloaded model on-device — it takes no API key (the model
    /// is loaded straight from the HF cache; the token is only for downloading).
    var needsAPIKey: Bool { self != .local && self != .whisper }

    /// True when the model is a downloaded local one, chosen from the cache
    /// rather than typed/fetched from a provider's list.
    var isLocal: Bool { self == .local }

    /// Where to find the API key hint / signup.
    var keyHint: String {
        switch self {
        case .anthropic: return "sk-ant-…  (console.anthropic.com)"
        case .openai: return "sk-…  (platform.openai.com)"
        case .gemini: return "AIza…  (aistudio.google.com)"
        case .openaiCompatible: return "provider key for your base URL"
        case .local, .whisper: return ""
        }
    }

    /// Providers the Assistant hotkey can talk to — Whisper only transcribes,
    /// so it exists solely for the ground-truth picker.
    static var assistantChoices: [AssistantProvider] {
        allCases.filter { $0 != .whisper }
    }

    /// Keychain account name for this provider's API key.
    var keychainAccount: String { "provider.\(rawValue)" }
}

/// Non-secret assistant settings, persisted as JSON in UserDefaults. API keys
/// live in the Keychain (see `KeychainStore`), never here.
struct AssistantConfig: Codable, Equatable {
    /// The provider used when you trigger the assistant hotkey.
    var provider: AssistantProvider
    /// Per-provider model override, keyed by provider rawValue.
    var models: [String: String]
    /// Base URL for the OpenAI-compatible provider (e.g. an OpenRouter/Ollama URL).
    var baseURL: String
    /// Name of the prompt file (from /prompts) to use as the system prompt. Empty
    /// means "use the inline `systemPrompt` below" (Custom).
    var promptName: String
    /// Inline system prompt, used when `promptName` is empty (Custom).
    var systemPrompt: String
    /// When on, a full-screen screenshot is attached to every assistant call.
    var attachScreenshot: Bool
    /// Live model lists remembered per provider (rawValue → model ids). Populated
    /// only when you tap "Fetch live models"; persisted so the picker stays
    /// filled without re-fetching.
    var fetchedModels: [String: [String]]

    static let defaultSystemPrompt =
        "You are Slive, a concise voice assistant. The user speaks a question or "
        + "request; answer directly and briefly in plain text with no markdown."

    static let `default` = AssistantConfig(
        provider: .anthropic,
        models: [:],
        baseURL: "",
        promptName: "assistant",   // the shipped prompts/assistant.md
        systemPrompt: defaultSystemPrompt,
        attachScreenshot: false,
        fetchedModels: [:]
    )

    /// Effective model for a provider — the override if set, else its default.
    func model(for p: AssistantProvider) -> String {
        let m = (models[p.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? p.defaultModel : m
    }

    mutating func setModel(_ value: String, for p: AssistantProvider) {
        models[p.rawValue] = value
    }
}

extension AssistantConfig {
    /// Tolerant decoding: any missing field (e.g. one added in a later version)
    /// falls back to its default instead of failing the whole decode and wiping
    /// the user's saved settings. Defined in an extension so the memberwise
    /// initializer is preserved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(AssistantProvider.self, forKey: .provider) ?? .anthropic
        models = try c.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        promptName = try c.decodeIfPresent(String.self, forKey: .promptName) ?? "assistant"
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? Self.defaultSystemPrompt
        attachScreenshot = try c.decodeIfPresent(Bool.self, forKey: .attachScreenshot) ?? false
        fetchedModels = try c.decodeIfPresent([String: [String]].self, forKey: .fetchedModels) ?? [:]
    }
}
