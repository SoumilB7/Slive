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
    /// Tolerant decoding: any missing OR unreadable field (one added in a
    /// later version, a provider a newer build added) falls back to
    /// `.default`'s value instead of failing the whole decode and wiping the
    /// user's saved settings — one source of defaults, so a missing field and
    /// a fresh install agree. Defined in an extension so the memberwise
    /// initializer is preserved.
    init(from decoder: Decoder) throws {
        let d = Self.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        provider = field(.provider, d.provider)
        models = field(.models, d.models)
        baseURL = field(.baseURL, d.baseURL)
        promptName = field(.promptName, d.promptName)
        systemPrompt = field(.systemPrompt, d.systemPrompt)
        attachScreenshot = field(.attachScreenshot, d.attachScreenshot)
        fetchedModels = field(.fetchedModels, d.fetchedModels)
    }
}
