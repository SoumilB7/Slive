import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

/// Training sample format
@MainActor
enum SampleFormatTests {
    static let suite = TestSuite(name: "Sample format") { t in
        print("[Sample format]")
        // The on-disk JSONL format must round-trip with ISO-8601 dates — a
        // change here silently orphans every previously captured sample.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let sample = EditSample(
            id: "abc", createdAt: Date(timeIntervalSince1970: 1_752_700_000),
            app: "com.example.app", transcript: "hello world", finalText: "",
            edited: false, confidence: "audio", audioFile: "audio/abc.wav")
        if let data = try? encoder.encode(sample),
           let back = try? decoder.decode(EditSample.self, from: data) {
            t.check(back.id == sample.id && back.transcript == sample.transcript
                    && back.audioFile == sample.audioFile
                    && abs(back.createdAt.timeIntervalSince1970
                           - sample.createdAt.timeIntervalSince1970) < 1.0,
                  "sample round-trips with ISO dates")
        } else {
            t.check(false, "sample round-trips with ISO dates", "encode/decode threw")
        }

        // Legacy lines (edit-tracking era, no llm fields) must still decode.
        let legacy = """
        {"id":"x","createdAt":"2026-07-16T10:00:00Z","app":"com.a.b","transcript":"t",\
        "finalText":"t2","edited":true,"confidence":"high","audioFile":null}
        """
        if let s = try? decoder.decode(EditSample.self, from: legacy.data(using: .utf8)!) {
            t.check(s.edited && s.finalText == "t2" && s.audioFile == nil
                    && s.llmTranscript == nil && s.llmModel == nil,
                  "legacy sample decodes (llm fields nil)")
        } else {
            t.check(false, "legacy sample decodes (llm fields nil)", "decode threw")
        }

        // Ground-truth fields must round-trip.
        var withLLM = sample
        withLLM.llmTranscript = "hello world."
        withLLM.llmModel = "gemini-2.5-flash"
        if let data = try? encoder.encode(withLLM),
           let back = try? decoder.decode(EditSample.self, from: data) {
            t.check(back.llmTranscript == "hello world." && back.llmModel == "gemini-2.5-flash",
                  "ground-truth fields round-trip")
        } else {
            t.check(false, "ground-truth fields round-trip", "encode/decode threw")
        }

        var manual = withLLM
        manual.finalText = "the human-approved transcript"
        manual.edited = true
        manual.confidence = "manual"
        if let data = try? encoder.encode(manual),
           let back = try? decoder.decode(EditSample.self, from: data) {
            t.check(back.finalText == manual.finalText && back.edited
                    && back.confidence == "manual"
                    && back.llmTranscript == "hello world.",
                  "manual label round-trips without replacing model ground truth")
        } else {
            t.check(false, "manual label round-trips", "encode/decode threw")
        }

        // Agreement is additive: absent from rows that don't have one (so
        // every older line is written back byte-for-byte the same).
        if let data = try? encoder.encode(withLLM) {
            t.check(!String(decoding: data, as: UTF8.self).contains("llmAgreement"),
                  "nil agreement is omitted from the JSON line")
        }
        var agreed = withLLM
        agreed.llmAgreement = 0.75
        if let data = try? encoder.encode(agreed),
           let back = try? decoder.decode(EditSample.self, from: data) {
            t.equal(back.llmAgreement, 0.75, "consensus agreement round-trips")
        } else {
            t.check(false, "consensus agreement round-trips", "encode/decode threw")
        }

        // Slive Custom 4's format fields: additive like agreement — the app
        // rewrites the whole index from these fields, so they must survive
        // a round-trip and stay absent from rows without them.
        if let data = try? encoder.encode(agreed) {
            let line = String(decoding: data, as: UTF8.self)
            t.check(!line.contains("llmFormatted") && !line.contains("llmFormatStatus")
                    && !line.contains("llmFormatModel"), "nil format fields are omitted from the JSON line")
        }
        var formatted = agreed
        formatted.llmFormatted = "Three things:\n1. Fix it\n2. Test it\n3. Ship it"
        formatted.llmFormatStatus = "formatted"
        formatted.llmFormatModel = "gpt-5.5"
        if let data = try? encoder.encode(formatted),
           let back = try? decoder.decode(EditSample.self, from: data) {
            t.check(back.llmFormatted == formatted.llmFormatted && back.llmFormatStatus == "formatted"
                    && back.llmFormatModel == "gpt-5.5" && back.llmAgreement == 0.75,
                    "format fields round-trip")
            t.equal(back.keptFormat, formatted.llmFormatted, "a formatted label is kept")
        } else {
            t.check(false, "format fields round-trip", "encode/decode threw")
        }
        var rejected = formatted
        rejected.llmFormatted = "three things fix it test it ship it"
        rejected.llmFormatStatus = "rejected:list-under-3-items"
        t.equal(rejected.keptFormat, nil, "a rejected format isn't kept")
        rejected.llmFormatStatus = "unchanged"
        t.equal(rejected.keptFormat, rejected.llmFormatted, "an unchanged format is kept")
        let consensusRow = """
        {"id":"c","createdAt":"2026-11-01T10:00:00Z","app":null,"transcript":"t","finalText":"",\
        "edited":false,"confidence":"audio","audioFile":"audio/c.wav","llmTranscript":"T.",\
        "llmModel":"consensus · gpt-transcribe","llmAgreement":0.9}
        """
        if let s = try? decoder.decode(EditSample.self, from: Data(consensusRow.utf8)) {
            t.check(s.llmAgreement == 0.9 && s.llmFormatted == nil && s.llmFormatStatus == nil
                    && s.llmFormatModel == nil, "a pre-format consensus row decodes")
        } else {
            t.check(false, "a pre-format consensus row decodes", "decode threw")
        }

        // Index parse: a torn/garbled line is counted (so the file gets
        // copied aside before a rewrite drops it), blank lines are not, and
        // an invalid byte costs only its own line.
        if let good = try? encoder.encode(sample) {
            var index = good + Data([0x0A])
            index += Data("{\"id\":\"torn\",\"createdAt\":".utf8) + Data([0x0A])
            index += Data([0xFF, 0xFE, 0x0A, 0x20, 0x0A])
            index += good + Data([0x0A])
            let parsed = TrainingStore.parseIndex(index)
            t.check(parsed.samples.count == 2 && parsed.undecodable == 2,
                  "index parse keeps good lines, counts bad ones",
                  "\(parsed.samples.count) good, \(parsed.undecodable) bad")
            t.equal(TrainingStore.parseIndex(Data()).undecodable, 0, "empty index has nothing to back up")
        }
        t.check(TrainingStore.endsLine(Data([0x0A])) && TrainingStore.endsLine(nil)
                && !TrainingStore.endsLine(Data([0x7D])),
              "append starts a fresh line only after a torn one")
        t.equal(TrainingStore.corruptBackupURL(
                for: URL(fileURLWithPath: "/t/samples.jsonl"),
                at: Date(timeIntervalSince1970: 1_700_000_000)).path,
              "/t/samples.jsonl.corrupt-1700000000", "index backup name")

        // Data page summary: one pass, table (newest-first) order, look rows
        // ahead of way-off rows without duplicates.
        func row(_ id: String, label: String?, look: Bool = false) -> EditSample {
            var s = EditSample(id: id, createdAt: Date(), app: nil, transcript: "t",
                               finalText: "", edited: false, confidence: "audio",
                               audioFile: "audio/\(id).wav")
            s.llmTranscript = label
            s.llmModel = look ? "consensus · whisper-1" : nil
            s.llmAgreement = look ? 0.5 : nil
            return s
        }
        let rows = [row("a", label: nil), row("b", label: "x", look: true),
                    row("c", label: "x"), row("d", label: nil)]
        let summary = TrainingStore.summarize(
            rows, hasAudio: { $0.id != "d" }, isWayOff: { $0.id == "b" || $0.id == "c" })
        t.check(summary.audioCount == 3 && summary.missingCount == 1,
              "summary counts audio and unlabeled clips")
        t.equal(summary.wayOffIDs, ["c", "b"], "way-off ids newest first")
        t.equal(summary.checkIDs, ["b", "c"], "check jump: looks first, way-off deduped")
    }
}
