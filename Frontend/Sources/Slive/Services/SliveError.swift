import Foundation

/// The one error a call to the local Slive Server ends in. `errorDescription`
/// is what the UI shows; `reportable` decides whether it's a fault worth a
/// problem report or just life (a bad key, a cancel, a slow provider).
enum SliveError: LocalizedError, Equatable, CustomStringConvertible {
    /// The server isn't up and couldn't be started. Carries BackendManager's
    /// `lastSpawnError` when the spawn said why (no venv, port taken…).
    case serverDown(String?)
    /// The server answered, but not with something usable: a non-2xx status,
    /// or a 2xx carrying an error or no answer (an empty label, a provider
    /// failure inside a stream). `message` is the server's own words if any.
    case server(status: Int, message: String)
    /// No usable API key — absent, rejected or out of quota. Every request
    /// would fail the same way. The message is the full sentence shown.
    case missingKey(String)
    /// A 2xx body that didn't decode. The detail is for reports only.
    case decode(String)
    case timeout
    case cancelled
    /// Failed on the app's side: a request that couldn't be built or sent,
    /// a broken audio file, a missing setting.
    case local(String)

    var errorDescription: String? {
        switch self {
        case .serverDown(let reason):          return reason ?? "Local server didn't start."
        case .server(_, let message):          return message
        case .missingKey(let message):         return message
        case .decode:                          return "Unreadable response."
        case .timeout:                         return "The request timed out."
        case .cancelled:                       return "cancelled"
        case .local(let message):              return message
        }
    }

    /// Same text as `errorDescription`, so `"\(error)"` reads the same as
    /// `localizedDescription` (the assistant overlay interpolates the error).
    var description: String { errorDescription ?? "" }

    /// A real fault — offer it as a problem report. 5xx and unreadable
    /// replies are bugs; a 502 is the provider behind the server failing
    /// (outage, no network, refusal), which no Slive fix can help — the
    /// FailureReporter rule. A server that couldn't start for a reason
    /// BackendManager already names (and shows) is a setup problem.
    var reportable: Bool {
        switch self {
        case .server(let status, _):           return status >= 500 && status != 502
        case .decode, .local:                  return true
        case .serverDown(let reason):          return reason == nil
        case .missingKey, .timeout, .cancelled: return false
        }
    }

    /// The HTTP status of a server reply, nil for everything else.
    var status: Int? {
        if case .server(let status, _) = self { return status }
        return nil
    }

    // MARK: - Mapping

    /// The error for a reply, or nil when it's a 2xx. `notFound` is what a
    /// 404 means for this route, said plainly (a vanished job).
    static func from(status: Int, body: Data, notFound: String? = nil) -> SliveError? {
        guard !(200..<300).contains(status) else { return nil }
        if status == 404, let notFound { return .server(status: 404, message: notFound) }
        let message = serverMessage(in: body)
        // `{"error": …, "fatal": "auth" | "quota"}`: the key itself is the
        // problem (POST /label_consensus answers 401 with it).
        if let message, isFatal(body) { return .missingKey(message) }
        return .server(status: status, message: message ?? "Server error \(status).")
    }

    /// Any thrown error as a SliveError (a SliveError passes through).
    static func from(_ error: Error) -> SliveError {
        if let error = error as? SliveError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut:  return .timeout
            case .cancelled: return .cancelled
            default:         return .local(error.localizedDescription)
            }
        }
        if error is DecodingError { return .decode(String(describing: error)) }
        return .local(error.localizedDescription)
    }

    /// The message in a backend error body, or nil: `{"error": …}` from our
    /// handlers, or FastAPI's `{"detail": …}` (a string, or a list of
    /// validation items — a 422).
    static func serverMessage(in body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        if let e = obj["error"] as? String, !e.isEmpty { return e }
        if let d = obj["detail"] as? String, !d.isEmpty { return d }
        if let items = obj["detail"] as? [[String: Any]],
           let msg = items.first?["msg"] as? String, !msg.isEmpty {
            return msg
        }
        return nil
    }

    private static func isFatal(_ body: Data) -> Bool {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return obj?["fatal"] is String
    }
}
