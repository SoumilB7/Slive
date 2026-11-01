import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

/// Consensus labeling (scope, estimates, write coalescing)
@MainActor
enum LabelRunTests {
    static let suite = TestSuite(name: "Label run") { t in
        print("[Label run]")
        func sample(_ id: String, model: String? = nil, label: String? = "x",
                    human: String = "", agreement: Double? = nil) -> EditSample {
            var s = EditSample(id: id, createdAt: Date(), app: nil, transcript: "typed",
                               finalText: human, edited: !human.isEmpty, confidence: "audio",
                               audioFile: "audio/\(id).wav")
            s.llmTranscript = label
            s.llmModel = model
            s.llmAgreement = agreement
            return s
        }
        // Scope: every model label gets upgraded once; humans and consensus don't.
        t.check(LabelScope.needsConsensus(sample("a", label: nil), hasAudio: true),
              "unlabeled clip is in scope")
        t.check(LabelScope.needsConsensus(sample("b", model: "gpt-4o-transcribe"), hasAudio: true)
                && LabelScope.needsConsensus(sample("c", model: "large-v3"), hasAudio: true)
                && LabelScope.needsConsensus(sample("d", model: "gpt-audio"), hasAudio: true),
              "older model labels are upgraded")
        t.check(!LabelScope.needsConsensus(sample("e", model: "consensus · whisper-1"), hasAudio: true),
              "consensus labels are skipped (re-click resumes)")
        t.check(!LabelScope.needsConsensus(sample("f", human: "human fix"), hasAudio: true),
              "human labels are never relabeled")
        t.check(!LabelScope.needsConsensus(sample("g", label: nil), hasAudio: false),
              "clips without audio are out of scope")
        t.equal(LabelScope.modelTag(chosen: "gpt-transcribe"), "consensus · gpt-transcribe",
              "consensus label tag names the winner")
        t.check(LabelScope.isConsensus(sample("h", model: LabelScope.modelTag(chosen: ""))),
              "a bare consensus tag still counts as consensus")
        t.check(LabelScope.needsALook(sample("i", model: "consensus · typed", agreement: 0.7))
                && !LabelScope.needsALook(sample("j", model: "consensus · typed", agreement: 0.9))
                && !LabelScope.needsALook(sample("k", model: "consensus", human: "ok", agreement: 0.2))
                && !LabelScope.needsALook(sample("l", model: "gemini-2.5-flash")),
              "low-agreement consensus labels (and only those) need a look")

        // Estimates.
        t.equal(LabelEstimate.audioSeconds(fileBytes: 4_096 + 64_000 * 30), 30,
              "audio seconds from a Float32 16 kHz capture's size")
        t.equal(LabelEstimate.audioSeconds(fileBytes: 100), 0, "header-only file is no audio")
        t.check(abs(LabelEstimate.dollars(audioSeconds: 600) - 0.105) < 1e-9,
              "cost is $0.0105 per audio minute (gpt-transcribe + whisper-1)")
        t.equal(LabelEstimate.runSeconds(clips: 8, audioSeconds: 0), 3,
              "run time divides by 4 clips in flight")
        t.equal(LabelEstimate.runSeconds(clips: 0, audioSeconds: 0), 0, "nothing to do takes no time")
        t.check(LabelEstimate.eta(processed: 3, total: 30, elapsed: 10) == nil,
              "no measured ETA until a full window is back")
        t.equal(LabelEstimate.eta(processed: 10, total: 30, elapsed: 20), 40,
              "ETA from observed throughput")
        t.equal(LabelEstimate.dollarsText(0.004), "<$0.01", "tiny cost text")
        t.equal(LabelEstimate.dollarsText(2.1), "~$2.10", "cost text")
        t.equal(LabelEstimate.durationText(20), "<1 min", "short duration text")
        t.equal(LabelEstimate.durationText(18 * 60), "~18 min", "minutes duration text")
        t.equal(LabelEstimate.durationText(80 * 60), "~1 h 20 min", "hours duration text")

        // The recipe lives outside AssistantProvider — it can't reach the
        // Assistant's pickers.
        t.check(AssistantProvider(rawValue: "consensus") == nil
                && !GroundTruthSource.singleProviders.contains(.anthropic),
              "consensus is a ground-truth recipe, never an assistant provider")
        t.equal(GroundTruthSource.consensus.title, "Slive Custom : 3 way check", "recipe picker title")

        // Response mapping: key problems stop the run, a bad clip doesn't.
        let fatal = #"{"error":"OpenAI rejected the key (401)","fatal":"auth"}"#
        // The card's prompt preview mirrors compose_prompt / parse_hotwords.
        t.check(GroundTruthClient.consensusPrompt(base: "", context: "")
                == GroundTruthClient.consensusDefaultBase, "consensus prompt defaults")
        t.check(GroundTruthClient.consensusPrompt(base: " Notes  for code. ", context: "Talks about Kore.")
                == "Notes for code. Talks about Kore.", "consensus prompt = base + context")
        t.check(GroundTruthClient.consensusKeywords("Kore, kore\nSlive,<x>, ") == ["Kore", "Slive"],
              "consensus keywords dedupe and drop markup")
        do {
            _ = try GroundTruthClient.decodeConsensus(Data(fatal.utf8))
            t.check(false, "fatal reply stops the run", "no error thrown")
        } catch let error as SliveError {
            t.check(error.stopsRun, "fatal reply stops the run")
        } catch {
            t.check(false, "fatal reply stops the run", "\(error)")
        }
        do {
            _ = try GroundTruthClient.decodeConsensus(Data(#"{"error":"Both transcribers failed"}"#.utf8))
            t.check(false, "per-clip failure keeps the run going", "no error thrown")
        } catch let error as SliveError {
            t.check(!error.stopsRun, "per-clip failure keeps the run going")
        } catch {
            t.check(false, "per-clip failure keeps the run going", "\(error)")
        }
        let ok = #"{"text":" Ship it. ","chosen":"whisper-1","agreement":0.93,"candidates":{"whisper-1":"Ship it."},"prompt":"p"}"#
        if let result = try? GroundTruthClient.decodeConsensus(Data(ok.utf8)) {
            t.check(result.text == "Ship it." && result.chosen == "whisper-1"
                    && result.agreement == 0.93 && result.prompt == "p",
                  "consensus reply decodes")
        } else {
            t.check(false, "consensus reply decodes", "decode threw")
        }

        // Write coalescing: a burst of labels is one index rewrite.
        var timers: [@MainActor () -> Void] = []
        var writes = 0
        let coalescer = IndexWriteCoalescer(schedule: { timers.append($0) }, write: { writes += 1 })
        for _ in 0..<100 { coalescer.markDirty() }
        t.check(writes == 0 && timers.count == 1 && coalescer.isPending,
              "100 labels schedule one write")
        timers[0]()
        t.check(writes == 1 && !coalescer.isPending, "the scheduled flush writes once")
        timers[0]()
        t.equal(writes, 1, "a stale timer doesn't write again")
        coalescer.markDirty()
        coalescer.flushNow()
        coalescer.flushNow()
        t.equal(writes, 2, "flushNow writes once, then is a no-op")
        timers[1]()
        t.equal(writes, 2, "the timer after an explicit flush is a no-op")
        coalescer.markDirty()
        coalescer.cancel()
        timers[2]()
        t.equal(writes, 2, "a full rewrite (cancel) satisfies the pending flush")
    }
}
