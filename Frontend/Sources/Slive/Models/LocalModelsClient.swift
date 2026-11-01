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

extension LocalCachedModel {
    /// The model repos in the Hugging Face cache, largest first — read straight
    /// from disk, so the Models page never starts the Python server just to
    /// list what's downloaded (it used to, and the server then stayed up).
    /// Same inventory as the backend's `scan_cache_dir`: size = the repo's blobs.
    nonisolated static func scanCache() -> [LocalCachedModel] {
        let env = ProcessInfo.processInfo.environment
        let root: URL
        if let hub = env["HF_HUB_CACHE"], !hub.isEmpty {
            root = URL(fileURLWithPath: hub)
        } else if let home = env["HF_HOME"], !home.isEmpty {
            root = URL(fileURLWithPath: home).appendingPathComponent("hub")
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub")
        }
        let fm = FileManager.default
        guard let repos = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var models: [LocalCachedModel] = []
        for dir in repos where dir.hasPrefix("models--") {
            let repoID = dir.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            let blobs = root.appendingPathComponent(dir).appendingPathComponent("blobs")
            var size: Int64 = 0
            var files = 0
            for name in (try? fm.contentsOfDirectory(atPath: blobs.path)) ?? [] {
                let attrs = try? fm.attributesOfItem(atPath: blobs.appendingPathComponent(name).path)
                size += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                files += 1
            }
            models.append(LocalCachedModel(repo_id: repoID, size_bytes: size, nb_files: files))
        }
        return models.sorted { $0.size_bytes > $1.size_bytes }
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

    /// Jobs live in the server's memory, so a 404 mid-poll means it restarted
    /// and the download is gone — said plainly, not as a decode error.
    static let jobGoneMessage = "Download stopped: the server restarted."

    func cachedModels() async throws -> [LocalCachedModel] {
        struct Resp: Decodable { let models: [LocalCachedModel] }
        let data = try await get("/local/cache", timeout: 30)
        return try JSONDecoder().decode(Resp.self, from: data).models
    }

    func startDownload(repoID: String, token: String) async throws -> String {
        struct Resp: Decodable { let job_id: String? }
        let body = ["repo_id": repoID, "token": token]
        let data = try await post("/local/download", body: body, timeout: 30)
        guard let id = try JSONDecoder().decode(Resp.self, from: data).job_id else {
            throw ServerError(message: "Download didn't start.")
        }
        return id
    }

    func downloadStatus(jobID: String) async throws -> LocalDownloadJob {
        let data = try await get("/local/download/\(jobID)", timeout: 15,
                                 notFound: Self.jobGoneMessage)
        return try JSONDecoder().decode(LocalDownloadJob.self, from: data)
    }

    func delete(repoID: String) async throws {
        // The server is lazy (and idle-stopped): bring it up, or the delete
        // fails with a bare "could not connect".
        guard await BackendManager.shared.ensureHealthy() else {
            let reason = await BackendManager.shared.lastSpawnError
            throw ServerError(message: reason ?? "Local server didn't start.")
        }
        _ = try await post("/local/delete", body: ["repo_id": repoID], timeout: 30)
    }

    // MARK: - HTTP

    private func get(_ path: String, timeout: TimeInterval, notFound: String? = nil) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: req)
        return try Self.checked(data, response, notFound: notFound)
    }

    private func post(_ path: String, body: [String: String], timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: req)
        return try Self.checked(data, response)
    }

    /// The body of a 2xx reply, else the server's message as an error.
    static func checked(_ data: Data, _ response: URLResponse, notFound: String? = nil) throws -> Data {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 404, let notFound { throw ServerError(message: notFound) }
            throw ServerError(message: AssistantClient.serverMessage(in: data)
                              ?? "Server error \(status).")
        }
        return data
    }
}
