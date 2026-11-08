import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

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
        var primed = sample("m", model: "consensus · gpt-transcribe", agreement: 0.81)
        primed.llmUnconfirmed = ["in", "bedrock", "hive", "netc"]
        var oneWord = sample("n", model: "consensus · gpt-transcribe", agreement: 0.95)
        oneWord.llmUnconfirmed = ["claude"]
        t.check(LabelScope.needsALook(primed) && !LabelScope.needsALook(oneWord),
              "2+ words only the label's transcriber heard need a look, whatever the agreement")
        t.equal(LabelScope.lookReason(primed), "Only one transcriber heard: in, bedrock, hive, netc · 81% agreement",
              "the ear's tooltip names those words")
        t.equal(LabelScope.lookReason(sample("o", model: "consensus", agreement: 0.7)), "70% agreement",
              "a plain low-agreement tooltip is unchanged")

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
        t.equal(GroundTruthSource.recipes.map(\.title),
                ["Slive Custom 4 : 3 way check + format", "Slive Custom : 3 way check"],
                "Custom 4 is listed first, the 3-way check right after")
        t.check(GroundTruthRecipe.consensusFormat.isConsensus && GroundTruthRecipe.consensus.isConsensus
                && !GroundTruthRecipe.single.isConsensus, "both Slive Custom recipes label by consensus")

        // Slive Custom 4's scope: missing consensus OR missing format step.
        func formattedRow(_ id: String, status: String?) -> EditSample {
            var s = sample(id, model: "consensus · gpt-transcribe", agreement: 0.9)
            s.llmFormatStatus = status
            return s
        }
        t.check(LabelScope.needsFormat(sample("m", label: nil), hasAudio: true)
                && LabelScope.needsFormat(sample("n", model: "gpt-audio"), hasAudio: true),
                "Custom 4: rows without a consensus label are in scope")
        t.check(LabelScope.needsFormat(formattedRow("o", status: nil), hasAudio: true),
                "Custom 4: a consensus row without the format step is in scope")
        t.check(!LabelScope.needsFormat(formattedRow("p", status: "formatted"), hasAudio: true)
                && !LabelScope.needsFormat(formattedRow("q", status: "rejected:list-under-3-items"), hasAudio: true)
                && !LabelScope.needsFormat(formattedRow("r", status: "skipped"), hasAudio: true),
                "Custom 4: a formatted, rejected or skipped row is done")
        t.check(!LabelScope.needsFormat(sample("s", human: "fix"), hasAudio: true)
                && !LabelScope.needsFormat(sample("u", label: nil), hasAudio: false),
                "Custom 4: human labels and clips without audio are out of scope")
        t.check(LabelScope.inScope(formattedRow("v", status: nil), recipe: .consensusFormat, hasAudio: true)
                && !LabelScope.inScope(formattedRow("w", status: nil), recipe: .consensus, hasAudio: true),
                "the scope follows the recipe")
        var lowAgreement = formattedRow("x", status: nil)
        lowAgreement.llmTranscript = "ship the build to staging"
        lowAgreement.llmAgreement = 0.6
        var shortLabel = formattedRow("y", status: nil)
        shortLabel.llmTranscript = "Ship it."
        var formatsLabel = formattedRow("z", status: nil)
        formatsLabel.llmTranscript = "ship the build to staging"
        t.check(LabelScope.formatWouldSkip(lowAgreement) && LabelScope.formatWouldSkip(shortLabel)
                && !LabelScope.formatWouldSkip(formatsLabel),
                "the estimate skips what the format step skips (agreement < 0.8, < 4 words)")

        // Custom 4's price: format-only rows pay only the format call.
        t.check(abs(LabelEstimate.formatDollars(calls: 100) - 1.5) < 1e-9, "a format call is ~$0.015")
        let formatOnly = LabelRun.Scope(ids: ["a", "b"], transcribeCount: 0, audioSeconds: 0, formatCalls: 2)
        t.check(abs(formatOnly.dollars - 0.03) < 1e-9, "a format-only row costs only the format call")
        let both = LabelRun.Scope(ids: ["a"], transcribeCount: 1, audioSeconds: 600, formatCalls: 1)
        t.check(abs(both.dollars - (0.105 + 0.015)) < 1e-9, "a new row costs the consensus plus the format call")
        t.equal(LabelEstimate.centsText(LabelEstimate.autoLabelDollarsPerDictation), "~$0.025",
                "per-dictation caption")

        // The format reply.
        let formatReply = #"{"formatted":"Ship it, then test it.","status":"formatted","model":"gpt-5.5"}"#
        if let result = try? LabelsAPI.Format.decodeResult(Data(formatReply.utf8)) {
            t.equal(result, GroundTruthClient.FormatResult(formatted: "Ship it, then test it.",
                                                           status: "formatted", model: "gpt-5.5"),
                    "format reply decodes")
        } else {
            t.check(false, "format reply decodes", "decode threw")
        }
        let formatBody = LabelsAPI.Format.Body(api_key: "k", label: "l", hotwords: "h", agreement: nil, word_count: 1)
        if let data = try? JSONEncoder().encode(formatBody) {
            t.check(!String(decoding: data, as: UTF8.self).contains("agreement"),
                    "no agreement is omitted (the backend's gate then passes)")
        }
        t.check(!LabelsAPI.Format(request: formatBody, quiet: true).reportsFailures
                && LabelsAPI.Format(request: formatBody).reportsFailures,
                "a background format call offers no problem report")

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
                    && result.agreement == 0.93 && result.prompt == "p" && result.unconfirmed.isEmpty,
                  "consensus reply decodes")
        } else {
            t.check(false, "consensus reply decodes", "decode threw")
        }

        let flagged = #"{"text":"x","chosen":"gpt-transcribe","agreement":0.81,"unconfirmed":["hive","netc"]}"#
        t.equal((try? GroundTruthClient.decodeConsensus(Data(flagged.utf8)))?.unconfirmed ?? [], ["hive", "netc"],
              "consensus reply carries the unconfirmed words")

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
