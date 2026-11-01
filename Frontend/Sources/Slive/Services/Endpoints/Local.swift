import Foundation

/// `/local/*` — the Hugging Face cache the local provider runs from.
enum LocalAPI {
    /// Jobs live in the server's memory, so a 404 mid-poll means it restarted
    /// and the download is gone — said plainly, not as a decode error.
    static let jobGoneMessage = "Download stopped: the server restarted."

    struct Cache: Endpoint {
        struct Reply: Decodable { let models: [LocalCachedModel] }
        typealias Response = Reply
        let path = "/local/cache"
    }

    struct StartDownload: Endpoint {
        struct Reply: Decodable { let job_id: String? }
        typealias Response = Reply
        let repoID: String
        let token: String
        let path = "/local/download"
        let method = "POST"
        var body: (any Encodable)? { ["repo_id": repoID, "token": token] }
    }

    /// Polled while a download runs — never restarts a server that's gone.
    struct DownloadStatus: Endpoint {
        typealias Response = LocalDownloadJob
        let jobID: String
        var path: String { "/local/download/\(jobID)" }
        let timeout: TimeInterval = 15
        let ensuresServer = false
        var notFoundMessage: String? { LocalAPI.jobGoneMessage }
    }

    struct Delete: Endpoint {
        typealias Response = Ignored
        let repoID: String
        let path = "/local/delete"
        let method = "POST"
        var body: (any Encodable)? { ["repo_id": repoID] }
    }
}
