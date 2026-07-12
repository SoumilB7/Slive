import Foundation

struct WhisperTrainingModel: Decodable, Identifiable {
    let id: String
    let label: String
    let hfModel: String
    let family: String
    let multilingual: Bool
    let detail: String
    // The size-aware training profile the backend picked for this checkpoint:
    // smaller models take more adapter capacity and update more often; large
    // ones move slower and accumulate longer.
    let learningRate: Double
    let loraRank: Int
    let gradientAccumulationSteps: Int
    let klEvery: Int

    private enum CodingKeys: String, CodingKey {
        case id, label, family, multilingual, detail
        case hfModel = "hf_model"
        case learningRate = "learning_rate"
        case loraRank = "lora_rank"
        case gradientAccumulationSteps = "gradient_accumulation_steps"
        case klEvery = "kl_every"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        hfModel = try c.decode(String.self, forKey: .hfModel)
        family = try c.decode(String.self, forKey: .family)
        multilingual = try c.decode(Bool.self, forKey: .multilingual)
        detail = try c.decode(String.self, forKey: .detail)
        // Tolerate a backend one release behind (no profile fields yet).
        learningRate = try c.decodeIfPresent(Double.self, forKey: .learningRate) ?? 0
        loraRank = try c.decodeIfPresent(Int.self, forKey: .loraRank) ?? 0
        gradientAccumulationSteps = try c.decodeIfPresent(Int.self, forKey: .gradientAccumulationSteps) ?? 0
        klEvery = try c.decodeIfPresent(Int.self, forKey: .klEvery) ?? 0
    }

    /// The profile as one mono line, e.g. "lr 5e-6 · r=4 · accum 16 · KL ¼".
    var profileSummary: String? {
        guard learningRate > 0, loraRank > 0 else { return nil }
        let lr = String(format: "%g", learningRate)
        var parts = ["lr \(lr)", "r=\(loraRank)", "accum \(gradientAccumulationSteps)"]
        if klEvery > 0 { parts.append("KL every \(klEvery)") }
        return parts.joined(separator: " · ")
    }
}

struct TrainingReadiness: Decodable {
    let eligibleCount: Int
    let requiredSamples: Int
    let remainingSamples: Int
    let ready: Bool
    let eligibleAudioMinutes: Double
    /// Second gate: total eligible audio must reach this many minutes — fifty
    /// one-second clips are not a dataset.
    let requiredAudioMinutes: Double

    private enum CodingKeys: String, CodingKey {
        case eligibleCount = "eligible_count"
        case requiredSamples = "required_samples"
        case remainingSamples = "remaining_samples"
        case ready
        case eligibleAudioMinutes = "eligible_audio_minutes"
        case requiredAudioMinutes = "required_audio_minutes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eligibleCount = try c.decode(Int.self, forKey: .eligibleCount)
        requiredSamples = try c.decode(Int.self, forKey: .requiredSamples)
        remainingSamples = try c.decode(Int.self, forKey: .remainingSamples)
        ready = try c.decode(Bool.self, forKey: .ready)
        eligibleAudioMinutes = try c.decode(Double.self, forKey: .eligibleAudioMinutes)
        // Tolerate a backend one release behind (no minutes gate yet).
        requiredAudioMinutes = try c.decodeIfPresent(Double.self, forKey: .requiredAudioMinutes) ?? 0
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
    let sourceModel: String
    let baseModel: String
    let method: String
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
        case sourceModel = "source_model"
        case baseModel = "base_model"
        case method
        case eligibleSamples = "eligible_samples"
        case requiredSamples = "required_samples"
        case installedModelDir = "installed_model_dir"
        case totalUpdates = "total_updates"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        modelName = try c.decode(String.self, forKey: .modelName)
        sourceModel = try c.decodeIfPresent(String.self, forKey: .sourceModel) ?? "large-v3-v20240930_626MB"
        baseModel = try c.decodeIfPresent(String.self, forKey: .baseModel) ?? "openai/whisper-large-v3"
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "lora"
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

    func models() async throws -> [WhisperTrainingModel] {
        guard await BackendManager.shared.ensureHealthy() else {
            throw TrainingError(message: "Couldn't start the training backend.")
        }
        let data = try await request("/training/models")
        return try JSONDecoder().decode(ModelEnvelope.self, from: data).models
    }

    func start(sourceModel: String, method: String) async throws -> WhisperTrainingJob {
        guard await BackendManager.shared.ensureHealthy() else {
            throw TrainingError(message: "Couldn't start the training backend.")
        }
        let body = try JSONEncoder().encode(StartRequest(sourceModel: sourceModel, method: method))
        let data = try await request("/training/start", method: "POST", body: body)
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
    private struct ModelEnvelope: Decodable { let models: [WhisperTrainingModel] }
    private struct ErrorEnvelope: Decodable { let error: String }
    private struct StartRequest: Encodable {
        let sourceModel: String
        let method: String
        enum CodingKeys: String, CodingKey { case sourceModel = "source_model", method }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
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
