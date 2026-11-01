import Foundation

/// The exact system prompt the most recent assistant ask was sent with —
/// inspectable from the Assistant page, same idea as the ground-truth card's
/// "Last prompt sent": what went in is a look, not a guess.
@MainActor
final class AssistantPromptLog: ObservableObject {
    static let shared = AssistantPromptLog()
    @Published private(set) var lastSystemPrompt: String?
    @Published private(set) var lastMeta: String?

    func record(prompt: String?, provider: String, model: String) {
        lastSystemPrompt = prompt
        lastMeta = "\(provider) · \(model)"
    }
}

/// Talks to the local backend's assistant proxy: sends the transcribed
/// prompt plus the chosen provider/model/key and returns the LLM's answer.
/// The routes and wire format are `AssistantAPI`.
struct AssistantClient {

    var timeout: TimeInterval = 90   // LLMs can take a while

    /// One image attached to a request (base64 PNG/JPEG bytes + media type).
    struct ImageInput: Encodable {
        let media_type: String
        let data: String
    }

    /// One prior conversation turn: role is "user" or "assistant".
    struct HistoryItem: Encodable {
        let role: String
        let content: String
    }

    /// Fetch the provider's LIVE list of model ids (via the backend `/models`).
    func listModels(config: AssistantConfig, apiKey: String) async throws -> [String] {
        let provider = config.provider
        try Self.requireKey(apiKey, for: provider)
        let body = AssistantAPI.Models.Body(
            provider: provider.wire,
            api_key: apiKey,
            base_url: provider.needsBaseURL ? config.baseURL : nil
        )
        return try await LocalServer.send(AssistantAPI.Models(request: body)).models
    }

    /// Build the shared POST body for a prompt.
    private func makeBody(_ text: String, config: AssistantConfig, apiKey: String,
                          images: [ImageInput]?, history: [HistoryItem]?) -> AssistantAPI.Request {
        let provider = config.provider
        let localOpts = provider.isLocal ? Settings.localInferenceOptions() : nil
        let systemPrompt = PromptLibrary.resolvedSystemPrompt(for: config)
        let model = config.model(for: provider)
        Task { @MainActor in
            AssistantPromptLog.shared.record(
                prompt: systemPrompt, provider: provider.displayName, model: model)
        }
        return AssistantAPI.Request(
            text: text,
            provider: provider.wire,
            model: model,
            api_key: apiKey,
            base_url: provider.needsBaseURL ? config.baseURL : nil,
            system_prompt: systemPrompt,
            max_tokens: 1024,
            images: (images?.isEmpty ?? true) ? nil : images,
            history: (history?.isEmpty ?? true) ? nil : history,
            local_quantized: localOpts?.quantized,
            local_mem_gb: localOpts?.memGB
        )
    }

    /// The checks every ask makes before anything is sent, and its timeout:
    /// a local model may need its first-use load (multi-GB weights) before
    /// any tokens appear — far more slack than a cloud call.
    private func prepare(_ config: AssistantConfig, apiKey: String) throws -> TimeInterval {
        let provider = config.provider
        try Self.requireKey(apiKey, for: provider)
        if provider.isLocal && config.model(for: .local).isEmpty {
            throw SliveError.local("No local model chosen.")
        }
        return provider.isLocal ? max(timeout, 600) : timeout
    }

    private static func requireKey(_ apiKey: String, for provider: AssistantProvider) throws {
        guard !apiKey.isEmpty || !provider.needsAPIKey else {
            throw SliveError.missingKey("No \(provider.displayName) key. Add one in Providers.")
        }
    }

    /// Stream the assistant's reply as it's generated, yielding text deltas.
    /// The consumer accumulates them. Finishes (throwing) on any failure.
    func askStream(_ text: String, config: AssistantConfig, apiKey: String,
                   images: [ImageInput]? = nil, history: [HistoryItem]? = nil)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let timeout = try prepare(config, apiKey: apiKey)
                    let lines = try await LocalServer.lines(AssistantAPI.Stream(
                        request: makeBody(text, config: config, apiKey: apiKey, images: images, history: history),
                        timeout: timeout))

                    // Provider failures (overloaded, safety block, empty
                    // answer) arrive as an {"error": …} line and throw below.
                    for try await line in lines {
                        if Task.isCancelled { break }
                        guard let data = line.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(AssistantAPI.Chunk.self, from: data)
                        else { continue }
                        if let err = chunk.error { throw SliveError.server(status: 200, message: err) }
                        if chunk.done == true { break }
                        if let d = chunk.delta { continuation.yield(d) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Send `text` to the assistant using `config` (+ its Keychain key) and
    /// return the answer. Throws with a human-readable message on failure.
    func ask(_ text: String, config: AssistantConfig, apiKey: String,
             images: [ImageInput]? = nil, history: [HistoryItem]? = nil) async throws -> String {
        let timeout = try prepare(config, apiKey: apiKey)
        let body = makeBody(text, config: config, apiKey: apiKey, images: images, history: history)
        return try await LocalServer.send(AssistantAPI.Ask(request: body, timeout: timeout)).text
    }
}
