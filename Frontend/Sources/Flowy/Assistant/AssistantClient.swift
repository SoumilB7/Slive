import Foundation

/// Talks to the local backend's `/assistant` endpoint: sends the transcribed
/// prompt plus the chosen provider/model/key and returns the LLM's answer.
///
/// Wire format:
///   POST http://127.0.0.1:50711/assistant
///   Content-Type: application/json
///   body: { text, provider, model, api_key, base_url?, system_prompt?, max_tokens? }
///   200 → { "text": "<answer>" }
///   non-200 → { "error": "<message>" }
struct AssistantClient {

    var endpoint: URL = URL(string: "http://127.0.0.1:50711/assistant")!
    var timeout: TimeInterval = 90   // LLMs can take a while

    enum AssistantError: Error, CustomStringConvertible {
        case missingKey(String)
        case notHTTP
        case server(String)
        case badStatus(Int)
        case decodeFailed

        var description: String {
            switch self {
            case .missingKey(let p):  return "No API key set for \(p). Add one in Settings → Assistant."
            case .notHTTP:            return "Assistant: no HTTP response"
            case .server(let m):      return m
            case .badStatus(let c):   return "Assistant: HTTP \(c)"
            case .decodeFailed:       return "Assistant: could not decode response"
            }
        }
    }

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

    private struct RequestBody: Encodable {
        let text: String
        let provider: String
        let model: String
        let api_key: String
        let base_url: String?
        let system_prompt: String?
        let max_tokens: Int
        let images: [ImageInput]?
        let history: [HistoryItem]?
    }
    private struct OKPayload: Decodable { let text: String }
    private struct ErrPayload: Decodable { let error: String }
    private struct ModelsPayload: Decodable { let models: [String] }
    private struct ModelsBody: Encodable {
        let provider: String
        let api_key: String
        let base_url: String?
    }

    /// Fetch the provider's LIVE list of model ids (via the backend `/models`).
    func listModels(config: AssistantConfig, apiKey: String) async throws -> [String] {
        let provider = config.provider
        guard !apiKey.isEmpty else { throw AssistantError.missingKey(provider.displayName) }

        let body = ModelsBody(
            provider: provider.wire,
            api_key: apiKey,
            base_url: provider.needsBaseURL ? config.baseURL : nil
        )
        var request = URLRequest(url: URL(string: "http://127.0.0.1:50711/models")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 30

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfig)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AssistantError.notHTTP }
        guard http.statusCode == 200 else {
            if let err = try? JSONDecoder().decode(ErrPayload.self, from: data) {
                throw AssistantError.server(err.error)
            }
            throw AssistantError.badStatus(http.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(ModelsPayload.self, from: data) else {
            throw AssistantError.decodeFailed
        }
        return payload.models
    }

    private struct StreamChunk: Decodable {
        let delta: String?
        let error: String?
        let done: Bool?
    }

    /// Build the shared POST body for a prompt.
    private func makeBody(_ text: String, config: AssistantConfig, apiKey: String,
                          images: [ImageInput]?, history: [HistoryItem]?) -> RequestBody {
        let provider = config.provider
        return RequestBody(
            text: text,
            provider: provider.wire,
            model: config.model(for: provider),
            api_key: apiKey,
            base_url: provider.needsBaseURL ? config.baseURL : nil,
            system_prompt: PromptLibrary.resolvedSystemPrompt(for: config),
            max_tokens: 1024,
            images: (images?.isEmpty ?? true) ? nil : images,
            history: (history?.isEmpty ?? true) ? nil : history
        )
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
                    guard !apiKey.isEmpty else {
                        throw AssistantError.missingKey(config.provider.displayName)
                    }
                    var request = URLRequest(
                        url: URL(string: "http://127.0.0.1:50711/assistant/stream")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(
                        makeBody(text, config: config, apiKey: apiKey, images: images, history: history))
                    request.timeoutInterval = timeout

                    let cfg = URLSessionConfiguration.ephemeral
                    cfg.timeoutIntervalForRequest = timeout
                    cfg.timeoutIntervalForResource = timeout
                    cfg.waitsForConnectivity = false
                    let session = URLSession(configuration: cfg)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AssistantError.notHTTP }
                    guard http.statusCode == 200 else { throw AssistantError.badStatus(http.statusCode) }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let data = line.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data)
                        else { continue }
                        if let err = chunk.error { throw AssistantError.server(err) }
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
        let provider = config.provider
        guard !apiKey.isEmpty else { throw AssistantError.missingKey(provider.displayName) }

        let body = makeBody(text, config: config, apiKey: apiKey, images: images, history: history)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = timeout

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        sessionConfig.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfig)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AssistantError.notHTTP }

        guard http.statusCode == 200 else {
            // Prefer the server's error message when present.
            if let err = try? JSONDecoder().decode(ErrPayload.self, from: data) {
                throw AssistantError.server(err.error)
            }
            throw AssistantError.badStatus(http.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(OKPayload.self, from: data) else {
            throw AssistantError.decodeFailed
        }
        return payload.text
    }
}
