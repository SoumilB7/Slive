import Foundation

/// `/training/*` — fine-tuning a Whisper model on the user's corrections.
enum TrainingAPI {
    struct JobReply: Decodable { let job: WhisperTrainingJob }
    struct OptionalJobReply: Decodable { let job: WhisperTrainingJob? }

    struct Readiness: Endpoint {
        typealias Response = TrainingReadiness
        let path = "/training/readiness"
    }

    struct Models: Endpoint {
        struct Reply: Decodable { let models: [WhisperTrainingModel] }
        typealias Response = Reply
        let path = "/training/models"
    }

    struct Start: Endpoint {
        typealias Response = JobReply
        struct Body: Encodable {
            let sourceModel: String
            let method: String
            let name: String?
            let maxRamGB: Double
            enum CodingKeys: String, CodingKey {
                case sourceModel = "source_model", method, name
                case maxRamGB = "max_ram_gb"
            }
        }
        let request: Body
        let path = "/training/start"
        let method = "POST"
        var body: (any Encodable)? { request }
    }

    struct Latest: Endpoint {
        typealias Response = OptionalJobReply
        let path = "/training/jobs/latest"
    }

    /// Finish a run that failed after training (merge → convert → install).
    struct Resume: Endpoint {
        typealias Response = JobReply
        let id: String
        var path: String { "/training/jobs/\(id)/resume" }
        let method = "POST"
    }

    /// Polled while a job runs — never restarts a server that's gone.
    struct Status: Endpoint {
        typealias Response = JobReply
        let id: String
        var path: String { "/training/jobs/\(id)" }
        let ensuresServer = false
    }
}
