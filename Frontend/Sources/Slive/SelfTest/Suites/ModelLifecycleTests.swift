import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

/// Model lifecycle (folders, tokenizer, timeouts, cooldown)
@MainActor
enum ModelLifecycleTests {
    static let suite = TestSuite(name: "Model lifecycle") { t in
        print("[Model lifecycle]")
        // Exact folder match: "large-v3" once matched distil-large-v3 too.
        let names = ["openai_whisper-large-v3", "distil-whisper_distil-large-v3",
                     "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-tiny.en"]
        t.equal(TranscriptionModel.folderName(for: "large-v3", among: names), "openai_whisper-large-v3",
              "large-v3 → its own folder")
        t.equal(TranscriptionModel.folderName(for: "large-v3-v20240930_626MB", among: names),
              "openai_whisper-large-v3-v20240930_626MB", "turbo → its own folder")
        t.equal(TranscriptionModel.folderName(for: "distil-large-v3", among: names),
              "distil-whisper_distil-large-v3", "non-openai variant → <org>_<variant>")
        t.equal(TranscriptionModel.folderName(for: "large-v3", among: ["distil-whisper_distil-large-v3"]), nil,
              "large-v3 never matches distil-large-v3's folder")
        t.equal(TranscriptionModel.folderName(for: "v3", among: names), nil, "no loose suffix match")

        // The tokenizer the load will look for (WhisperKit's own detection).
        t.equal(TranscriptionModel.whisperVariant(vocabSize: 51866, dModel: 1280).description, "large-v3",
              "large-v3 / turbo → whisper-large-v3 tokenizer")
        t.equal(TranscriptionModel.whisperVariant(vocabSize: 51864, dModel: 384).description, "tiny.en",
              "tiny.en tokenizer")
        t.equal(TranscriptionModel.whisperVariant(vocabSize: 51864, dModel: 512).description, "base.en",
              "base.en tokenizer")
        t.equal(TranscriptionModel.whisperVariant(vocabSize: 51865, dModel: 1280).description, "large-v2",
              "large-v2 tokenizer")

        t.equal(TranscriptionModel.decodeTimeoutSeconds(audioSeconds: 0), 60, "decode timeout floor")
        t.equal(TranscriptionModel.decodeTimeoutSeconds(audioSeconds: 30), 120, "decode timeout grows with audio")

        let gb: UInt64 = 1 << 30
        t.check(TranscriptionModel.cpuCopyDelay(model: "large-v3-v20240930_626MB", physicalMemory: 8 * gb) >= 150,
              "large model on 8 GB: CPU copy later, never skipped")
        t.check(TranscriptionModel.cpuCopyDelay(model: "large-v3-v20240930_626MB", physicalMemory: 16 * gb) == TranscriptionModel.cpuCopyAfterSeconds,
              "large model on 16 GB: CPU copy at the usual time")
        t.check(TranscriptionModel.cpuCopyDelay(model: "tiny.en", physicalMemory: 8 * gb) == TranscriptionModel.cpuCopyAfterSeconds,
              "small model on 8 GB: CPU copy at the usual time")

        let now = Date()
        t.check(!TranscriptionModel.inCooldown(failedAt: nil, now: now), "never failed → no cooldown")
        t.check(TranscriptionModel.inCooldown(failedAt: now.addingTimeInterval(-10), now: now),
              "just failed → cooldown")
        t.check(!TranscriptionModel.inCooldown(
            failedAt: now.addingTimeInterval(-TranscriptionModel.failedLoadCooldownSeconds - 1), now: now),
              "cooldown ends")
    }
}
