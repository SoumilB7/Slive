import Foundation

/// Ground-truth labels for captured dictations: `/transcribe_llm` (one
/// audio-capable model) and `/label_consensus` (the 3-way check).
enum LabelsAPI {
    /// The server's shipped default transcription instruction.
    struct DefaultPrompt: Endpoint {
        struct Reply: Decodable { let prompt: String }
        typealias Response = Reply
        let path = "/transcribe_llm/prompt"
        let timeout: TimeInterval = 15
    }

    struct Transcribe: Endpoint {
        /// A usable label: non-empty text, plus the exact prompt the model saw.
        struct Label: Decodable {
            let text: String
            let prompt: String?
        }
        typealias Response = Label

        struct Body: Encodable {
            let provider: String
            let model: String
            let api_key: String
            let audio_b64: String
            let media_type: String
            let base_url: String?
            // Local-provider knobs; nil (omitted) for cloud providers.
            let local_quantized: Bool?
            let local_mem_gb: Double?
            // The user's Vocabulary (hotwords + context) so the judge spells
            // names and terms the way the main model was told to.
            let vocab_hint: String?
            // The user's edited base instruction (nil = the server default).
            let prompt_override: String?
        }
        let request: Body
        let isLocal: Bool
        let path = "/transcribe_llm"
        let method = "POST"
        var body: (any Encodable)? { request }
        // Long clips + provider latency; a local model may also need its
        // first-use load (multi-GB weights) before it can transcribe.
        var timeout: TimeInterval { isLocal ? 600 : 120 }

        private struct Reply: Decodable {
            let text: String?
            let error: String?
            let prompt: String?
        }

        func decode(_ data: Data) throws -> Label { try Self.decodeLabel(data) }

        static func decodeLabel(_ data: Data) throws -> Label {
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            if let error = reply.error { throw SliveError.server(status: 200, message: error) }
            let text = (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw SliveError.server(status: 200, message: "No text returned.") }
            return Label(text: text, prompt: reply.prompt)
        }
    }

    struct Consensus: Endpoint {
        typealias Response = GroundTruthClient.ConsensusResult

        struct Body: Encodable {
            let api_key: String
            let audio_b64: String
            let media_type: String
            let typed: String
            let hotwords: String
            let context: String
            let base_prompt: String
        }
        let request: Body
        /// A background label: failures aren't offered as problem reports.
        var quiet = false
        let path = "/label_consensus"
        let method = "POST"
        var body: (any Encodable)? { request }
        // Two hosted calls in parallel, each retried with backoff on 429/5xx.
        let timeout: TimeInterval = 300
        var reportsFailures: Bool { !quiet }

        private struct Reply: Decodable {
            let text: String?
            let chosen: String?
            let agreement: Double?
            let candidates: [String: String]?
            let prompt: String?
            let error: String?
            /// "auth" | "quota" when the key itself is the problem.
            let fatal: String?
        }

        func decode(_ data: Data) throws -> GroundTruthClient.ConsensusResult {
            try Self.decodeResult(data)
        }

        static func decodeResult(_ data: Data) throws -> GroundTruthClient.ConsensusResult {
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            if let error = reply.error {
                throw reply.fatal != nil ? SliveError.missingKey(error)
                                         : SliveError.server(status: 200, message: error)
            }
            let text = (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw SliveError.server(status: 200, message: "No text returned.")
            }
            return GroundTruthClient.ConsensusResult(
                text: text, chosen: reply.chosen ?? "", agreement: reply.agreement ?? 0,
                candidates: reply.candidates ?? [:], prompt: reply.prompt)
        }
    }

    /// Slive Custom 4's step 4: format one consensus label (gpt-5.5, then a
    /// code check of every edit).
    struct Format: Endpoint {
        typealias Response = GroundTruthClient.FormatResult

        struct Body: Encodable {
            let api_key: String
            let label: String
            let hotwords: String
            /// nil (omitted) = no agreement gate.
            let agreement: Double?
            let word_count: Int
        }
        let request: Body
        /// A background label: failures aren't offered as problem reports.
        var quiet = false
        let path = "/label_format"
        let method = "POST"
        var body: (any Encodable)? { request }
        // One chat call (up to 180 s server-side), retried on 429/5xx.
        let timeout: TimeInterval = 300
        var reportsFailures: Bool { !quiet }

        func decode(_ data: Data) throws -> GroundTruthClient.FormatResult { try Self.decodeResult(data) }

        static func decodeResult(_ data: Data) throws -> GroundTruthClient.FormatResult {
            let result = try JSONDecoder().decode(GroundTruthClient.FormatResult.self, from: data)
            guard !result.status.isEmpty, !result.formatted.isEmpty else {
                throw SliveError.server(status: 200, message: "No text returned.")
            }
            return result
        }
    }

    /// The formatter's system instruction (read-only in the app).
    struct FormatPrompt: Endpoint {
        struct Reply: Decodable { let prompt: String }
        typealias Response = Reply
        let path = "/label_format/prompt"
        let timeout: TimeInterval = 15
    }
}
