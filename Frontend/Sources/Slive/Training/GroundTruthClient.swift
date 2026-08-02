import Foundation

/// Fetches ground-truth transcriptions for captured dictation audio from an
/// audio-capable multimodal model, through the same local Python proxy the
/// assistant uses (`POST /transcribe_llm`). The provider/model/key travel per
/// request; nothing is stored server-side.
struct GroundTruthClient {
    private let endpoint = URL(string: "http://127.0.0.1:50711/transcribe_llm")!

    enum GroundTruthError: LocalizedError {
        case missingKey(String)
        case backendDown
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missingKey(let provider):
                return "No API key for \(provider) — set it below."
            case .backendDown:
                return "Backend didn't come up — try again in a moment."
            case .server(let message):
                return message
            }
        }
    }

    private struct RequestBody: Encodable {
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

    private struct ResponseBody: Decodable {
        let text: String?
        let error: String?
        let prompt: String?
    }

    /// Transcribe one audio file. Brings the backend up if needed (it's lazy).
    /// Returns the transcript AND the exact prompt the model was seeded with
    /// (vocabulary hint included) so the UI can show what went in.
    func transcribe(audioURL: URL,
                    provider: AssistantProvider,
                    model: String,
                    apiKey: String,
                    baseURL: String?,
                    vocabHint: String? = nil) async throws -> (text: String, prompt: String?) {
        guard !apiKey.isEmpty || !provider.needsAPIKey else {
            throw GroundTruthError.missingKey(provider.displayName)
        }
        if provider.isLocal && model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw GroundTruthError.server(
                "No local model picked — choose a downloaded audio-capable model.")
        }
        guard await BackendManager.shared.ensureHealthy() else {
            throw GroundTruthError.backendDown
        }

        let audio = try Data(contentsOf: audioURL)
        let localOpts = provider.isLocal ? Settings.localInferenceOptions() : nil
        let body = RequestBody(
            provider: provider.wire,
            model: model,
            api_key: apiKey,
            audio_b64: audio.base64EncodedString(),
            media_type: "audio/wav",
            base_url: (baseURL?.isEmpty ?? true) ? nil : baseURL,
            local_quantized: localOpts?.quantized,
            local_mem_gb: localOpts?.memGB,
            vocab_hint: vocabHint)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        // Long clips + provider latency; a local model may also need its
        // first-use load (multi-GB weights) before it can transcribe.
        request.timeoutInterval = provider.isLocal ? 600 : 120

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        if let error = decoded.error { throw GroundTruthError.server(error) }
        return ((decoded.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                decoded.prompt)
    }
}
