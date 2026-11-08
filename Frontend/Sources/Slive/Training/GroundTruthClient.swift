import Foundation

/// Fetches ground-truth transcriptions for captured dictation audio from an
/// audio-capable multimodal model, through the same local Python proxy the
/// assistant uses (`POST /transcribe_llm`). The provider/model/key travel per
/// request; nothing is stored server-side. The routes are `LabelsAPI`.
struct GroundTruthClient {
    /// Where the consensus recipe's key lives, said exactly.
    static let missingOpenAIKeyMessage =
        "Needs an OpenAI key."

    /// The server's shipped default transcription instruction — the prompt
    /// editor's starting point and its Reset target.
    func defaultPrompt() async throws -> String {
        try await LocalServer.send(LabelsAPI.DefaultPrompt()).prompt
    }

    /// Map a /transcribe_llm reply to text + prompt, or the right error —
    /// split out so the self-test can check it without a server. A non-2xx
    /// throws the server's own message: FastAPI's 422 carries `detail`, not
    /// `error`, and used to decode as an empty label.
    static func decodeTranscription(_ data: Data, _ response: URLResponse) throws -> (text: String, prompt: String?) {
        do {
            let label = try LabelsAPI.Transcribe.decodeLabel(LocalServer.validate(data, response))
            return (label.text, label.prompt)
        } catch {
            throw SliveError.from(error)
        }
    }

    /// The consensus speaker line when the user hasn't edited it. Mirrors
    /// DEFAULT_CONTEXT in Backend/src/flowy/label_consensus.py.
    static let consensusDefaultBase =
        "Dictation to a computer: prompts, messages and notes, often technical."

    /// What gpt-transcribe gets as its prompt — mirrors compose_prompt().
    static func consensusPrompt(base: String, context: String) -> String {
        func squash(_ s: String) -> String {
            String(s.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(400))
        }
        let head = squash(base).isEmpty ? consensusDefaultBase : squash(base)
        let ctx = squash(context)
        return ctx.isEmpty ? head : "\(head) \(ctx)"
    }

    /// gpt-transcribe's keywords — mirrors parse_hotwords(): comma/newline
    /// separated, whitespace collapsed, first spelling wins, no markup, ≤ 50.
    static func consensusKeywords(_ raw: String) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for part in raw.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" }) {
            let word = part.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !word.isEmpty, !word.contains("<"), !word.contains(">"),
                  seen.insert(word.lowercased()).inserted else { continue }
            words.append(word)
        }
        return Array(words.prefix(50))
    }

    /// The vocabulary context that rides with every ground-truth request —
    /// the SAME "possible words" the user gave the main dictation model
    /// (Settings → Vocabulary), so the judge gets their spellings right
    /// without endless hand-fixes. nil when nothing is configured.
    static func vocabHint(hotwords: String, context: String) -> String? {
        let words = hotwords.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty || !ctx.isEmpty else { return nil }
        var parts: [String] = []
        if !words.isEmpty {
            parts.append("Words and names this speaker likely uses — prefer these exact spellings when the audio matches: \(words).")
        }
        if !ctx.isEmpty {
            parts.append("Speaker context: \(ctx)")
        }
        return parts.joined(separator: " ")
    }

    /// Transcribe one audio file. Brings the backend up if needed (it's lazy).
    /// Returns the transcript AND the exact prompt the model was seeded with
    /// (vocabulary hint included) so the UI can show what went in.
    func transcribe(audioURL: URL,
                    provider: AssistantProvider,
                    model: String,
                    apiKey: String,
                    baseURL: String?,
                    vocabHint: String? = nil,
                    promptOverride: String? = nil) async throws -> (text: String, prompt: String?) {
        guard !apiKey.isEmpty || !provider.needsAPIKey else {
            throw SliveError.missingKey("No \(provider.displayName) key.")
        }
        if provider.isLocal && model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SliveError.local("No local model chosen.")
        }

        let audio = try Data(contentsOf: audioURL)
        let localOpts = provider.isLocal ? Settings.localInferenceOptions() : nil
        let body = LabelsAPI.Transcribe.Body(
            provider: provider.wire,
            model: model,
            api_key: apiKey,
            audio_b64: audio.base64EncodedString(),
            media_type: "audio/wav",
            base_url: (baseURL?.isEmpty ?? true) ? nil : baseURL,
            local_quantized: localOpts?.quantized,
            local_mem_gb: localOpts?.memGB,
            vocab_hint: vocabHint,
            prompt_override: promptOverride)
        let label = try await LocalServer.send(LabelsAPI.Transcribe(request: body, isLocal: provider.isLocal))
        return (label.text, label.prompt)
    }

    // MARK: - 3-way consensus (POST /label_consensus)

    /// One consensus label: gpt-transcribe (steered by the Vocabulary) writes it,
    /// and whisper-1 plus Slive's own typed text vote on how far to trust it.
    struct ConsensusResult: Decodable {
        let text: String
        /// "gpt-transcribe" | "whisper-1" | "typed"
        let chosen: String
        /// 0…1 — how closely the candidates agreed.
        let agreement: Double
        let candidates: [String: String]
        /// The prompt + keywords gpt-transcribe was given.
        let prompt: String?
    }

    /// Map the endpoint's JSON to a result or the right error — split out
    /// so the self-test can check the fatal mapping without a server.
    static func decodeConsensus(_ data: Data) throws -> ConsensusResult {
        do { return try LabelsAPI.Consensus.decodeResult(data) } catch { throw SliveError.from(error) }
    }

    /// `quiet`: no problem report on failure (background labels).
    func consensus(audioURL: URL, apiKey: String, typed: String,
                   hotwords: String, context: String, base: String,
                   quiet: Bool = false) async throws -> ConsensusResult {
        guard !apiKey.isEmpty else {
            throw SliveError.missingKey(Self.missingOpenAIKeyMessage)
        }
        let audio = try Data(contentsOf: audioURL)
        let body = LabelsAPI.Consensus.Body(
            api_key: apiKey, audio_b64: audio.base64EncodedString(),
            media_type: "audio/wav", typed: typed, hotwords: hotwords, context: context,
            base_prompt: base)
        // The status counts now (it used to be ignored): a key problem is a
        // 401 whose `fatal` flag stops the run; a 422 says what was wrong.
        return try await LocalServer.send(LabelsAPI.Consensus(request: body, quiet: quiet))
    }

    // MARK: - Slive Custom 4's format step (POST /label_format)

    /// The formatter's verdict on one consensus label.
    struct FormatResult: Decodable, Equatable {
        /// The formatted text when kept (formatted / unchanged), else the plain label.
        let formatted: String
        /// `formatted` | `unchanged` | `rejected:<reason>` | `skipped`
        let status: String
        let model: String
    }

    /// Format one stored consensus label. The backend skips (no API call)
    /// what the training gate would reject anyway.
    func format(label: String, apiKey: String, hotwords: String, agreement: Double?,
                quiet: Bool = false) async throws -> FormatResult {
        guard !apiKey.isEmpty else {
            throw SliveError.missingKey(Self.missingOpenAIKeyMessage)
        }
        let body = LabelsAPI.Format.Body(
            api_key: apiKey, label: label, hotwords: hotwords, agreement: agreement,
            word_count: label.split(whereSeparator: \.isWhitespace).count)
        return try await LocalServer.send(LabelsAPI.Format(request: body, quiet: quiet))
    }

    /// The formatter's system instruction, as the backend sends it.
    func formatPrompt() async throws -> String {
        try await LocalServer.send(LabelsAPI.FormatPrompt()).prompt
    }
}

extension SliveError {
    /// Whether a bulk label run should stop instead of counting a failure:
    /// a key problem or a dead server fails every clip the same way.
    var stopsRun: Bool {
        switch self {
        case .missingKey, .serverDown: return true
        default: return false
        }
    }
}
