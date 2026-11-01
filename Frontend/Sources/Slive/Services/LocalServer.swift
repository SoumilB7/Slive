import Foundation

/// One route on the local Slive Server, declared once: path, method, body,
/// timeout and how it's sent. Every requirement but `path` has a default.
/// Routes live in `Services/Endpoints/`, grouped by area.
protocol Endpoint {
    associatedtype Response: Decodable
    var path: String { get }
    var method: String { get }
    /// JSON body; nil = none (and no Content-Type).
    var body: (any Encodable)? { get }
    var timeout: TimeInterval { get }
    /// A fresh ephemeral session per call that fails at once instead of
    /// waiting for connectivity (the assistant's calls). false = `.shared`.
    var ephemeral: Bool { get }
    /// Also cap the whole transfer at `timeout`, not just each idle gap
    /// (ephemeral sessions only).
    var capsResource: Bool { get }
    var cachePolicy: URLRequest.CachePolicy { get }
    /// Bring the server up first — it's lazy and idle-stopped. Polls and
    /// health probes opt out: they ask about a server that should be up.
    var ensuresServer: Bool { get }
    /// Offer reportable failures as problem reports (health probes opt out).
    var reportsFailures: Bool { get }
    /// What a 404 means for this route, said plainly (nil = the server's words).
    var notFoundMessage: String? { get }
    /// A 2xx body → the response. Throw a SliveError for a reply that
    /// decodes but isn't usable.
    func decode(_ data: Data) throws -> Response
}

extension Endpoint {
    var method: String { "GET" }
    var body: (any Encodable)? { nil }
    var timeout: TimeInterval { 30 }
    var ephemeral: Bool { false }
    var capsResource: Bool { false }
    var cachePolicy: URLRequest.CachePolicy { .useProtocolCachePolicy }
    var ensuresServer: Bool { true }
    var reportsFailures: Bool { true }
    var notFoundMessage: String? { nil }

    func decode(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    var url: URL { ServerConfig.url(path) }

    func urlRequest() throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = cachePolicy
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }
}

/// A route whose body the caller doesn't read.
struct Ignored: Decodable {}

extension Endpoint where Response == Ignored {
    func decode(_ data: Data) throws -> Ignored { Ignored() }
}

/// The one HTTP layer to the local Slive Server. Every failure comes out as
/// a SliveError; reportable ones are offered as problem reports, attributed
/// to the caller's line.
enum LocalServer {
    /// Send `endpoint` and decode its reply.
    static func send<E: Endpoint>(_ endpoint: E, file: String = #fileID, line: Int = #line,
                                  function: String = #function) async throws -> E.Response {
        do {
            try await ensureServer(for: endpoint)
            let request = try endpoint.urlRequest()
            let session = session(for: endpoint)
            defer { if endpoint.ephemeral { session.finishTasksAndInvalidate() } }
            let (data, response) = try await session.data(for: request)
            return try endpoint.decode(validate(data, response, notFound: endpoint.notFoundMessage))
        } catch {
            throw fail(error, endpoint, file: file, line: line, function: function)
        }
    }

    /// Send `endpoint` and read its reply as NDJSON lines as they arrive
    /// (the assistant stream). A non-2xx reply throws with the server's own
    /// message, not a bare status.
    static func lines<E: Endpoint>(_ endpoint: E, file: String = #fileID, line: Int = #line,
                                   function: String = #function) async throws -> ServerLines {
        do {
            try await ensureServer(for: endpoint)
            let request = try endpoint.urlRequest()
            let session = session(for: endpoint)
            // Lets the open stream finish, then frees the session.
            defer { if endpoint.ephemeral { session.finishTasksAndInvalidate() } }
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) {
                // Read the (small) error body so the server's message shows
                // instead of a bare "HTTP 422".
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 65_536 { break }
                }
                _ = try validate(body, response)
            }
            return ServerLines(lines: bytes.lines) { error in
                fail(error, endpoint, file: file, line: line, function: function)
            }
        } catch {
            throw fail(error, endpoint, file: file, line: line, function: function)
        }
    }

    /// The body of a 2xx reply, else the reply's error.
    static func validate(_ data: Data, _ response: URLResponse, notFound: String? = nil) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw SliveError.local("No response from the server.")
        }
        if let failure = SliveError.from(status: http.statusCode, body: data, notFound: notFound) {
            throw failure
        }
        return data
    }

    // MARK: - Internals

    private static func ensureServer<E: Endpoint>(for endpoint: E) async throws {
        guard endpoint.ensuresServer else { return }
        guard await BackendManager.shared.ensureHealthy() else {
            throw SliveError.serverDown(await BackendManager.shared.lastSpawnError)
        }
    }

    private static func session<E: Endpoint>(for endpoint: E) -> URLSession {
        guard endpoint.ephemeral else { return .shared }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = endpoint.timeout
        if endpoint.capsResource { config.timeoutIntervalForResource = endpoint.timeout }
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// Map `error`, offer it as a report if it's a fault, and hand it back.
    private static func fail<E: Endpoint>(_ error: Error, _ endpoint: E, file: String, line: Int,
                                          function: String) -> SliveError {
        let failure = SliveError.from(error)
        if endpoint.reportsFailures {
            var detail = "\(endpoint.method) \(endpoint.path)"
            if case .decode(let why) = failure { detail += " · \(why)" }
            if let status = failure.status { detail += " · HTTP \(status)" }
            FailureReporter.shared.report(failure, area: "server", title: reportTitle(failure),
                                          detail: detail, serverLog: true,
                                          file: file, line: line, function: function)
        }
        return failure
    }

    private static func reportTitle(_ error: SliveError) -> String {
        switch error {
        case .server:     return "The Slive Server hit an error."
        case .decode:     return "The Slive Server sent an unreadable reply."
        case .serverDown: return "The Slive Server didn't start."
        default:          return "A Slive Server request failed."
        }
    }
}

/// An NDJSON reply, line by line; a failure mid-stream (timeout, the server
/// dying) comes out as a SliveError like any other.
struct ServerLines: AsyncSequence {
    typealias Element = String
    let lines: AsyncLineSequence<URLSession.AsyncBytes>
    let fail: (Error) -> SliveError

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator
        let fail: (Error) -> SliveError

        mutating func next() async throws -> String? {
            do { return try await base.next() } catch { throw fail(error) }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: lines.makeAsyncIterator(), fail: fail)
    }
}
