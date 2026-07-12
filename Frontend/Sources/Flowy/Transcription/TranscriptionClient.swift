import Foundation

/// Talks to the local transcription backend. POSTs the raw MP3 bytes and
/// returns the transcribed text.
///
/// Wire format:
///   POST http://127.0.0.1:50711/transcribe
///   Content-Type: audio/mpeg
///   body: raw MP3 file bytes
///   200 → { "text": "<string>" }
struct TranscriptionClient {

    var endpoint: URL = URL(string: "http://127.0.0.1:50711/transcribe")!
    /// Generous — local models can take a moment to spin up on the first hit.
    var timeout: TimeInterval = 60

    enum TranscriptionError: Error, CustomStringConvertible {
        case notHTTP
        case badStatus(Int)
        case decodeFailed

        var description: String {
            switch self {
            case .notHTTP:            return "Transcription: no HTTP response"
            case .badStatus(let c):   return "Transcription: HTTP \(c)"
            case .decodeFailed:       return "Transcription: could not decode response"
            }
        }
    }

    private struct Payload: Decodable { let text: String }

    /// Send `audioURL`'s bytes to the backend and return the transcript.
    /// Throws on transport errors, non-200 status, or an undecodable body.
    func transcribe(_ audioURL: URL) async throws -> String {
        let bytes = try Data(contentsOf: audioURL)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("audio/mpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = bytes
        request.timeoutInterval = timeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.notHTTP
        }
        guard http.statusCode == 200 else {
            throw TranscriptionError.badStatus(http.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw TranscriptionError.decodeFailed
        }
        return payload.text
    }
}
