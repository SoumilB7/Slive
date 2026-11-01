import Foundation

/// Non-secret assistant settings, persisted as JSON in UserDefaults. API keys
/// live in the Keychain (see `CredentialStore`), never here.
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
        provider: .openai,
        models: ["openai": "gpt-5.4-mini"],
        baseURL: "",
        promptName: "rewrite",     // the shipped prompts/rewrite.md
        systemPrompt: defaultSystemPrompt,
        attachScreenshot: true,
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

    /// The one base URL a provider needs (OpenAI-compatible only). Ground truth
    /// and assistant share it — it's provider config, not per-feature config.
    func baseURL(for p: AssistantProvider) -> String {
        p.needsBaseURL ? baseURL : ""
    }
}

extension AssistantConfig {
    /// Tolerant decoding: any missing field (e.g. one added in a later version)
    /// falls back to `.default`'s value instead of failing the whole decode and
    /// wiping the user's saved settings — one source of defaults, so a missing
    /// field and a fresh install agree. Defined in an extension so the
    /// memberwise initializer is preserved.
    init(from decoder: Decoder) throws {
        let d = Self.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(AssistantProvider.self, forKey: .provider) ?? d.provider
        models = try c.decodeIfPresent([String: String].self, forKey: .models) ?? d.models
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        promptName = try c.decodeIfPresent(String.self, forKey: .promptName) ?? d.promptName
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt
        attachScreenshot = try c.decodeIfPresent(Bool.self, forKey: .attachScreenshot) ?? d.attachScreenshot
        fetchedModels = try c.decodeIfPresent([String: [String]].self, forKey: .fetchedModels) ?? d.fetchedModels
    }
}
