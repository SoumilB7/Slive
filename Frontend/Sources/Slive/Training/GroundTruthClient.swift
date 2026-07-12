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
    }

    private struct ResponseBody: Decodable {
        let text: String?
        let error: String?
    }

    /// Transcribe one audio file. Brings the backend up if needed (it's lazy).
    func transcribe(audioURL: URL,
                    provider: AssistantProvider,
                    model: String,
                    apiKey: String,
                    baseURL: String?) async throws -> String {
        guard !apiKey.isEmpty else {
            throw GroundTruthError.missingKey(provider.displayName)
        }
        guard await BackendManager.shared.ensureHealthy() else {
            throw GroundTruthError.backendDown
        }

        let audio = try Data(contentsOf: audioURL)
        let body = RequestBody(
            provider: provider.wire,
            model: model,
            api_key: apiKey,
            audio_b64: audio.base64EncodedString(),
            media_type: "audio/wav",
            base_url: (baseURL?.isEmpty ?? true) ? nil : baseURL)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 120   // long clips + provider latency

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        if let error = decoded.error { throw GroundTruthError.server(error) }
        return (decoded.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
