import Foundation

/// Routes about the server itself.
enum ServerAPI {
    /// `GET /health` — up, and whether a download, training job or request
    /// is running (the idle shutdown waits for it). Probes the server, so it
    /// never starts one and a miss is never a problem report.
    struct Health: Endpoint {
        struct Reply: Decodable { let busy: Bool? }
        typealias Response = Reply
        let path = "/health"
        let timeout: TimeInterval = 1.5
        let cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
        let ensuresServer = false
        let reportsFailures = false
    }
}
