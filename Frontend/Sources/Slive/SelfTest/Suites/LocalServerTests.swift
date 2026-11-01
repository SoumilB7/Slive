import Foundation
import SliveTestKit

/// The HTTP layer to the local server: reply validation and how each
/// endpoint builds its request.
@MainActor
enum LocalServerTests {
    static let suite = TestSuite(name: "Local server") { t in
        print("[Local server]")
        func json(_ s: String) -> Data { Data(s.utf8) }
        func reply(_ status: Int) -> URLResponse {
            HTTPURLResponse(url: ServerConfig.url("/x"), statusCode: status,
                            httpVersion: nil, headerFields: nil)!
        }

        // What a status means for a label run, and the raw-reply check
        // (SliveError's own mapping: SliveErrorTests in SliveCoreSuites).
        let fatal = SliveError.from(status: 401, body: json(#"{"error":"OpenAI rejected the key (401)","fatal":"auth"}"#))
        t.check(fatal?.stopsRun == true, "status: a fatal reply stops a label run")
        t.check(SliveError.from(status: 502, body: json(#"{"error":"x"}"#))?.stopsRun == false,
                "status: a per-clip failure keeps a label run going")
        t.equal(message { try LocalServer.validate(Data(), URLResponse()) }, "No response from the server.",
                "validate: a non-HTTP reply")
        t.equal(message { try LocalServer.validate(json("{}"), reply(422)) }, "Server error 422.",
                "validate: a non-2xx throws")

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
