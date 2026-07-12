import Foundation

struct TrainingReadiness: Decodable {
    let eligibleCount: Int
    let requiredSamples: Int
    let remainingSamples: Int
    let ready: Bool
    let eligibleAudioMinutes: Double

    private enum CodingKeys: String, CodingKey {
        case eligibleCount = "eligible_count"
        case requiredSamples = "required_samples"
        case remainingSamples = "remaining_samples"
        case ready
        case eligibleAudioMinutes = "eligible_audio_minutes"
    }
}

/// One training-loop telemetry point: cross-entropy loss on your corrected
/// transcripts every update; KL divergence from stock Balanced (nats/token)
/// sampled every few updates.
struct TrainingMetric: Decodable, Equatable {
    let update: Int
    let epoch: Int
    let loss: Double
    let kl: Double?
}

struct WhisperTrainingJob: Decodable {
    let id: String
    let modelName: String
    let state: String
    let stage: String
    let message: String
    let progress: Double
    let eligibleSamples: Int
    let requiredSamples: Int
    let installedModelDir: String?
    let error: String?
    let metrics: [TrainingMetric]
    let totalUpdates: Int

    private enum CodingKeys: String, CodingKey {
        case id, state, stage, message, progress, error, metrics
        case modelName = "model_name"
        case eligibleSamples = "eligible_samples"
        case requiredSamples = "required_samples"
        case installedModelDir = "installed_model_dir"
        case totalUpdates = "total_updates"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        modelName = try c.decode(String.self, forKey: .modelName)
        state = try c.decode(String.self, forKey: .state)
        stage = try c.decode(String.self, forKey: .stage)
        message = try c.decode(String.self, forKey: .message)
        progress = try c.decode(Double.self, forKey: .progress)
        eligibleSamples = try c.decode(Int.self, forKey: .eligibleSamples)
        requiredSamples = try c.decode(Int.self, forKey: .requiredSamples)
        installedModelDir = try c.decodeIfPresent(String.self, forKey: .installedModelDir)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        // Tolerate a backend one release behind (no telemetry fields yet).
        metrics = try c.decodeIfPresent([TrainingMetric].self, forKey: .metrics) ?? []
        totalUpdates = try c.decodeIfPresent(Int.self, forKey: .totalUpdates) ?? 0
    }

    var isActive: Bool { state == "queued" || state == "running" }
}

struct TrainingClient {
    private let base = URL(string: "http://127.0.0.1:50711")!

    struct TrainingError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func readiness() async throws -> TrainingReadiness {
        guard await BackendManager.shared.ensureHealthy() else {
            throw TrainingError(message: "Couldn't start the training backend.")
        }
        let data = try await request("/training/readiness")
        return try JSONDecoder().decode(TrainingReadiness.self, from: data)
    }

    func start() async throws -> WhisperTrainingJob {
        guard await BackendManager.shared.ensureHealthy() else {
            throw TrainingError(message: "Couldn't start the training backend.")
        }
        let data = try await request("/training/start", method: "POST")
        return try JSONDecoder().decode(JobEnvelope.self, from: data).job
    }

    func latest() async throws -> WhisperTrainingJob? {
        guard await BackendManager.shared.ensureHealthy() else {
            throw TrainingError(message: "Couldn't start the training backend.")
        }
        let data = try await request("/training/jobs/latest")
        return try JSONDecoder().decode(OptionalJobEnvelope.self, from: data).job
    }

    func status(id: String) async throws -> WhisperTrainingJob {
        let data = try await request("/training/jobs/\(id)")
        return try JSONDecoder().decode(JobEnvelope.self, from: data).job
    }

    private struct JobEnvelope: Decodable { let job: WhisperTrainingJob }
    private struct OptionalJobEnvelope: Decodable { let job: WhisperTrainingJob? }
    private struct ErrorEnvelope: Decodable { let error: String }

    private func request(_ path: String, method: String = "GET") async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrainingError(message: "Training backend returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error)
                ?? "Training backend returned HTTP \(http.statusCode)."
            throw TrainingError(message: message)
        }
        return data
    }
}

