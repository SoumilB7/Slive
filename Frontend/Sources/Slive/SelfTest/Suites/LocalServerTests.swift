import Foundation

/// The HTTP layer to the local server: error bodies, status → SliveError,
/// what gets reported, and how each endpoint builds its request.
@MainActor
enum LocalServerTests {
    static let suite = TestSuite(name: "Local server") { t in
        print("[Local server]")
        func json(_ s: String) -> Data { Data(s.utf8) }
        func reply(_ status: Int) -> URLResponse {
            HTTPURLResponse(url: ServerConfig.url("/x"), statusCode: status,
                            httpVersion: nil, headerFields: nil)!
        }

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
        t.check(fatal?.stopsRun == true, "status: a fatal reply stops a label run")
        t.check(SliveError.from(status: 502, body: json(#"{"error":"x"}"#))?.stopsRun == false,
                "status: a per-clip failure keeps a label run going")
        t.equal(message { try LocalServer.validate(Data(), URLResponse()) }, "No response from the server.",
                "validate: a non-HTTP reply")
        t.equal(message { try LocalServer.validate(json("{}"), reply(422)) }, "Server error 422.",
                "validate: a non-2xx throws")

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

        // Endpoints: URL, method, body, timeout, session.
        t.equal(ServerConfig.baseURL.absoluteString, "http://127.0.0.1:50711", "config: base URL")
        t.equal(TrainingAPI.Status(id: "abc").url.absoluteString,
                "http://127.0.0.1:50711/training/jobs/abc", "endpoint: training status URL")
        t.equal(TrainingAPI.Resume(id: "abc").url.absoluteString,
                "http://127.0.0.1:50711/training/jobs/abc/resume", "endpoint: resume URL")
        t.equal(LocalAPI.DownloadStatus(jobID: "j1").url.absoluteString,
                "http://127.0.0.1:50711/local/download/j1", "endpoint: download status URL")
        let start = try? TrainingAPI.Start(request: .init(sourceModel: "m", method: "hybrid", name: nil,
                                                         maxRamGB: 12)).urlRequest()
        let startBody = start?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        t.check(start?.httpMethod == "POST" && start?.value(forHTTPHeaderField: "Content-Type") == "application/json"
                && startBody?["source_model"] as? String == "m" && startBody?["max_ram_gb"] as? Double == 12,
                "endpoint: training start posts its JSON body")
        let ready = try? TrainingAPI.Readiness().urlRequest()
        t.check(ready?.httpMethod == "GET" && ready?.httpBody == nil
                && ready?.value(forHTTPHeaderField: "Content-Type") == nil && ready?.timeoutInterval == 30,
                "endpoint: a GET has no body and the 30 s default")
        let resume = try? TrainingAPI.Resume(id: "a").urlRequest()
        t.check(resume?.httpMethod == "POST" && resume?.httpBody == nil, "endpoint: resume posts no body")
        let health = ServerAPI.Health()
        t.check(health.timeout == 1.5 && health.cachePolicy == .reloadIgnoringLocalCacheData
                && !health.ensuresServer && !health.reportsFailures, "endpoint: health probes quietly")
        t.check(!TrainingAPI.Status(id: "a").ensuresServer && !LocalAPI.DownloadStatus(jobID: "a").ensuresServer
                && TrainingAPI.Readiness().ensuresServer, "endpoint: polls never start the server")
        t.equal(LocalAPI.DownloadStatus(jobID: "a").notFoundMessage, LocalAPI.jobGoneMessage,
                "endpoint: a vanished download says so")
        let label = LabelsAPI.Transcribe.Body(provider: "p", model: "m", api_key: "", audio_b64: "",
                                              media_type: "audio/wav", base_url: nil, local_quantized: nil,
                                              local_mem_gb: nil, vocab_hint: nil, prompt_override: nil)
        t.check(LabelsAPI.Transcribe(request: label, isLocal: true).timeout == 600
                && LabelsAPI.Transcribe(request: label, isLocal: false).timeout == 120,
                "endpoint: a local label waits for the model load")
        t.equal(LabelsAPI.DefaultPrompt().timeout, 15, "endpoint: default prompt 15 s")
        let ask = AssistantAPI.Request(text: "", provider: "", model: "", api_key: "", base_url: nil,
                                       system_prompt: nil, max_tokens: 1024, images: nil, history: nil,
                                       local_quantized: nil, local_mem_gb: nil)
        let stream = AssistantAPI.Stream(request: ask, timeout: 600)
        t.check(stream.ephemeral && stream.capsResource && !stream.ensuresServer && stream.timeout == 600,
                "endpoint: the stream keeps its own capped session")
        let models = AssistantAPI.Models(request: .init(provider: "", api_key: "", base_url: nil))
        t.check(models.ephemeral && !models.capsResource && models.timeout == 30, "endpoint: model list session")
    }

    private static func message(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch { return error.localizedDescription }
    }
}
