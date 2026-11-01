import Foundation

/// Where the local Slive Server listens — said once. Loopback only: the
/// server rejects any request not addressed to a loopback host.
enum ServerConfig {
    static let host = "127.0.0.1"
    static let port = 50711
    static let baseURL = URL(string: "http://\(host):\(port)")!

    /// The full URL for a route path like `/training/jobs/<id>`.
    static func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }
}
