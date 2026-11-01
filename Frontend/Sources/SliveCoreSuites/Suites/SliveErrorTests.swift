import Foundation
import SliveCore
import SliveTestKit

/// SliveError: error bodies, status → SliveError, thrown errors, what the
/// person reads and what gets reported.
@MainActor
enum SliveErrorTests {
    static let suite = TestSuite(name: "Backend error mapping") { t in
        print("[Backend error mapping]")
        func json(_ s: String) -> Data { Data(s.utf8) }

        // Error bodies: ours, FastAPI's detail string, a 422's detail list.
        t.equal(SliveError.serverMessage(in: json(#"{"error":"Bad model."}"#)), "Bad model.", "body: error")
        t.equal(SliveError.serverMessage(in: json(#"{"detail":"Not Found"}"#)), "Not Found", "body: detail string")
        t.equal(SliveError.serverMessage(in: json(#"{"detail":[{"loc":["body","x"],"msg":"Field required"}]}"#)),
                "Field required", "body: 422 detail list")
        t.equal(SliveError.serverMessage(in: json(#"{"error":"","detail":"d"}"#)), "d", "body: empty error falls to detail")
        t.equal(SliveError.serverMessage(in: json("{}")), nil, "body: empty object has no message")
        t.equal(SliveError.serverMessage(in: json("Internal Server Error")), nil, "body: non-JSON has no message")

        // Status → SliveError.
        t.equal(SliveError.from(status: 200, body: Data()), nil, "status: 200 is not an error")
        t.equal(SliveError.from(status: 202, body: Data()), nil, "status: 202 is not an error")
        t.equal(SliveError.from(status: 500, body: json("oops")),
                .server(status: 500, message: "Server error 500."), "status: bare 500 reads plainly")
        t.equal(SliveError.from(status: 409, body: json(#"{"error":"A job is running."}"#)),
                .server(status: 409, message: "A job is running."), "status: the server's words win")
        t.equal(SliveError.from(status: 404, body: json(#"{"error":"Unknown job."}"#), notFound: "Gone."),
                .server(status: 404, message: "Gone."), "status: a route's 404 meaning")
        let fatal = SliveError.from(status: 401, body: json(#"{"error":"OpenAI rejected the key (401)","fatal":"auth"}"#))
        t.equal(fatal, .missingKey("OpenAI rejected the key (401)"), "status: a fatal reply is a key problem")

        // Thrown errors → SliveError.
        t.equal(SliveError.from(URLError(.timedOut)), .timeout, "thrown: URL timeout")
        t.equal(SliveError.from(URLError(.cancelled)), .cancelled, "thrown: URL cancel")
        t.equal(SliveError.from(CancellationError()), .cancelled, "thrown: task cancel")
        t.equal(SliveError.from(URLError(.cannotConnectToHost)),
                .local(URLError(.cannotConnectToHost).localizedDescription), "thrown: a refused connection keeps its text")
        t.equal(SliveError.from(SliveError.missingKey("k")), .missingKey("k"), "thrown: a SliveError passes through")
        let undecodable: Error
        do { _ = try JSONDecoder().decode([String: Int].self, from: json("[1]")); undecodable = SliveError.cancelled }
        catch { undecodable = error }
        if case .decode = SliveError.from(undecodable) { t.check(true, "thrown: a decode failure") }
        else { t.check(false, "thrown: a decode failure", "\(SliveError.from(undecodable))") }

        // What the person reads.
        t.equal(SliveError.serverDown(nil).localizedDescription, "Local server didn't start.", "text: server down")
        t.equal(SliveError.serverDown("Port 50711 is in use by another app.").localizedDescription,
                "Port 50711 is in use by another app.", "text: server down says why")
        t.equal(SliveError.decode("keyNotFound").localizedDescription, "Unreadable response.", "text: decode")
        t.equal("\(SliveError.missingKey("No OpenAI key. Add one in Providers."))",
                "No OpenAI key. Add one in Providers.", "text: interpolation reads like localizedDescription")

        // Reported: faults only.
        t.check(SliveError.server(status: 500, message: "").reportable, "report: 500")
        t.check(SliveError.server(status: 503, message: "").reportable, "report: 503")
        t.check(!SliveError.server(status: 502, message: "").reportable, "no report: 502 (the provider failed)")
        t.check(!SliveError.server(status: 422, message: "").reportable, "no report: 4xx")
        t.check(!SliveError.server(status: 200, message: "No text returned.").reportable, "no report: unusable 2xx")
        t.check(SliveError.decode("").reportable, "report: unreadable reply")
        t.check(SliveError.local("").reportable, "report: local failure")
        t.check(SliveError.serverDown(nil).reportable, "report: server down, no known reason")
        t.check(!SliveError.serverDown("Port taken").reportable, "no report: server down, reason shown")
        t.check(!SliveError.missingKey("").reportable, "no report: missing key")
        t.check(!SliveError.timeout.reportable, "no report: timeout")
        t.check(!SliveError.cancelled.reportable, "no report: cancel")
    }
}
