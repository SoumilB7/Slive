import Foundation

/// One model repo in the on-disk Hugging Face cache (the standard
/// `~/.cache/huggingface/hub`, shared with transformers / PyTorch).
struct LocalCachedModel: Identifiable, Decodable, Equatable {
    /// Cached repos smaller than this are config/tokenizer-only noise, not
    /// runnable models — the shared floor for the Models page and the
    /// Assistant / Ground Truth model pickers.
    static let minPickableBytes: Int64 = 50 * 1_048_576   // 50 MB

    let repo_id: String
    let size_bytes: Int64
    let nb_files: Int
    var id: String { repo_id }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size_bytes, countStyle: .file)
    }
}

/// State of a background download job on the backend.
struct LocalDownloadJob: Decodable {
    let id: String
    let repo_id: String
    let state: String       // running | done | error
    let message: String
    let path: String?
}

/// Talks to the backend's `/local/*` routes: read the HF cache, download a
/// model by id into it, poll the job, delete a cached model. Everything runs in
/// the Python backend; this is just the HTTP client.
struct LocalModelsClient {
    private let base = URL(string: "http://127.0.0.1:50711")!

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func cachedModels() async throws -> [LocalCachedModel] {
        struct Resp: Decodable { let models: [LocalCachedModel] }
        let (data, _) = try await get("/local/cache", timeout: 30)
        return try JSONDecoder().decode(Resp.self, from: data).models
    }

    func startDownload(repoID: String, token: String) async throws -> String {
        struct Resp: Decodable { let job_id: String?; let error: String? }
        let body = ["repo_id": repoID, "token": token]
        let (data, _) = try await post("/local/download", body: body, timeout: 30)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let error = resp.error { throw ServerError(message: error) }
        guard let id = resp.job_id else { throw ServerError(message: "No job id returned.") }
        return id
    }

    func downloadStatus(jobID: String) async throws -> LocalDownloadJob {
        let (data, _) = try await get("/local/download/\(jobID)", timeout: 15)
        return try JSONDecoder().decode(LocalDownloadJob.self, from: data)
    }

    func delete(repoID: String) async throws {
        struct Resp: Decodable { let error: String? }
        let (data, _) = try await post("/local/delete", body: ["repo_id": repoID], timeout: 30)
        if let error = try? JSONDecoder().decode(Resp.self, from: data).error {
            throw ServerError(message: error)
        }
    }

    // MARK: - HTTP

    private func get(_ path: String, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = timeout
        return try await URLSession.shared.data(for: req)
    }

    private func post(_ path: String, body: [String: String], timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = timeout
        return try await URLSession.shared.data(for: req)
    }
}
