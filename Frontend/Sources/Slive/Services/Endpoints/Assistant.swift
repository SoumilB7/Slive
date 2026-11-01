import Foundation

/// The assistant proxy: `/assistant`, `/assistant/stream`, `/models`. Each
/// call gets its own ephemeral session that fails at once instead of
/// waiting for connectivity.
enum AssistantAPI {
    /// The body of an ask (both the one-shot and the stream).
    struct Request: Encodable {
        let text: String
        let provider: String
        let model: String
        let api_key: String
        let base_url: String?
        let system_prompt: String?
        let max_tokens: Int
        let images: [AssistantClient.ImageInput]?
        let history: [AssistantClient.HistoryItem]?
        // Local-provider knobs; nil (omitted) for cloud providers.
        let local_quantized: Bool?
        let local_mem_gb: Double?
    }

    /// `POST /assistant` → `{ "text": "<answer>" }`.
    struct Ask: Endpoint {
        struct Reply: Decodable { let text: String }
        typealias Response = Reply
        let request: Request
        let timeout: TimeInterval
        let path = "/assistant"
        let method = "POST"
        var body: (any Encodable)? { request }
        let ephemeral = true
        let capsResource = true
    }

    /// `POST /assistant/stream` — NDJSON lines: `{"delta": …}` per chunk,
    /// `{"error": …}` if the provider fails, then `{"done": true}`.
    struct Stream: Endpoint {
        typealias Response = Never
        let request: Request
        let timeout: TimeInterval
        let path = "/assistant/stream"
        let method = "POST"
        var body: (any Encodable)? { request }
        let ephemeral = true
        let capsResource = true
        /// The assist path brought the server up a moment ago (and shows
        /// its own message when it can't) — no second probe before the ask.
        let ensuresServer = false
    }

    /// One line of the stream.
    struct Chunk: Decodable {
        let delta: String?
        let error: String?
        let done: Bool?
    }

    /// `POST /models` — the provider's LIVE list of model ids.
    struct Models: Endpoint {
        struct Reply: Decodable { let models: [String] }
        typealias Response = Reply
        struct Body: Encodable {
            let provider: String
            let api_key: String
            let base_url: String?
        }
        let request: Body
        let path = "/models"
        let method = "POST"
        var body: (any Encodable)? { request }
        let ephemeral = true
    }
}
