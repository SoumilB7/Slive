import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

/// Backend errors (server death, HTTP status → message)
@MainActor
enum BackendErrorTests {
    static let suite = TestSuite(name: "Backend errors") { t in
        print("[Backend errors]")
        let bound = "ERROR: [Errno 48] error while attempting to bind on address "
            + "('127.0.0.1', 50711): address already in use"
        t.equal(BackendManager.deathReason(code: 1, reason: .exit, logTail: bound),
              "Port 50711 is in use by another app.", "taken port is named as the reason")
        t.equal(BackendManager.deathReason(code: 1, reason: .exit, logTail: "ModuleNotFoundError"),
              "Slive Server quit on start (exit 1).", "other start-up deaths give the exit code")
        t.equal(BackendManager.deathReason(code: 9, reason: .uncaughtSignal, logTail: ""),
              "Slive Server quit on start (signal 9).", "a killed server says signal, not exit")

        func reply(_ status: Int) -> URLResponse {
            HTTPURLResponse(url: URL(string: "http://127.0.0.1:50711/x")!, statusCode: status,
                            httpVersion: nil, headerFields: nil)!
        }
        func message(_ body: () throws -> Any) -> String? {
            do { _ = try body(); return nil } catch { return error.localizedDescription }
        }
        let detail = Data(#"{"detail":[{"msg":"Field required"}]}"#.utf8)
        t.equal(message { try GroundTruthClient.decodeTranscription(detail, reply(422)) },
              "Field required", "ground truth: a 422 surfaces FastAPI's detail")
        t.equal(message { try GroundTruthClient.decodeTranscription(Data(#"{"text":"  "}"#.utf8), reply(200)) },
              "No text returned.", "ground truth: an empty label is an error, not stored")
        t.equal(message { try GroundTruthClient.decodeTranscription(Data("Internal Server Error".utf8), reply(500)) },
              "Server error 500.", "ground truth: a non-JSON 500 still reads plainly")
        let ok = try? GroundTruthClient.decodeTranscription(
            Data(#"{"text":" hello ","prompt":"p"}"#.utf8), reply(200))
        t.check(ok?.text == "hello" && ok?.prompt == "p", "ground truth: a good reply decodes")

        let gone = Data(#"{"error":"Unknown job."}"#.utf8)
        t.equal(message { try LocalServer.validate(gone, reply(404), notFound: LocalAPI.jobGoneMessage) },
              LocalAPI.jobGoneMessage, "local download: a vanished job ends the poll plainly")
        t.equal(message { try LocalServer.validate(Data(#"{"error":"Not in the cache."}"#.utf8), reply(404)) },
              "Not in the cache.", "local models: the server's own error wins")
    }
}
