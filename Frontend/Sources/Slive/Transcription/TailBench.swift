import Foundation

/// `Slive --bench-tail` — would a shorter post-release capture lose words?
///
/// Every captured clip ends with the post-release capture it was recorded
/// with (`--recorded`, default 0.3s — the setting through Sep 27, 2026).
/// Cutting the last `--cut` seconds (default 0.2) simulates a capture of
/// recorded − cut. A clip whose cut stretch is true
/// silence (≤ max(1.5 × room floor, 0.5 × trim threshold)) can't lose words;
/// every clip with sound in it is decoded both ways on the real model and
/// its ending compared. A sample of silent-tail clips is decoded too, as a
/// control that cutting silence changes nothing.
///
/// Flags: --cut <s> (0.2) · --since <yyyy-mm-dd> (2026-08-05, fixed-capture
/// era) · --limit <n> (300 newest) · --controls <n> (25) · --model <id>.
@MainActor
enum TailBench {
    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let model = value("--model") ?? "large-v3-v20240930_626MB"
        let cut = Double(value("--cut") ?? "") ?? 0.2
        let since = value("--since") ?? "2026-08-05"
        let limit = Int(value("--limit") ?? "") ?? 300
        let controls = Int(value("--controls") ?? "") ?? 25
        let recorded = Double(value("--recorded") ?? "") ?? 0.3

        let whisper = TranscriptionModel.shared
        guard await whisper.ensureLoaded(model) else { print("✗ model \(model) not available"); return 2 }
        _ = await whisper.transcribeSamples([Float](repeating: 0, count: 16_000), model: model)

        let clips = BenchSupport.loadClips(minSeconds: 0.8, limit: 100_000, since: since).prefix(limit)
        let cutSamples = Int(cut * 16_000)
        print(String(format: "%d clips since %@ · simulating a %.1fs capture (cutting the last %.1fs)",
                     clips.count, since, recorded - cut, cut))

        var silent = 0, withSound = 0, lost = 0, changed = 0, controlChanged = 0, controlRuns = 0
        var examples: [String] = []
        for clip in clips {
            guard let full = BenchSupport.readWAV(clip.url), full.count > cutSamples + 16_000 / 2 else { continue }
            let short = Array(full[0..<(full.count - cutSamples)])
            if isSilentTail(full, cutSamples: cutSamples) {
                silent += 1
                guard controlRuns < controls else { continue }
                controlRuns += 1
                let a = await decode(full, model: model), b = await decode(short, model: model)
                if BenchSupport.wer(b, a) > 0 { controlChanged += 1 }
                continue
            }
            withSound += 1
            let a = await decode(full, model: model), b = await decode(short, model: model)
            if BenchSupport.wer(b, a) > 0 { changed += 1 }
            if BenchSupport.lostEnding(early: b, today: a) {
                lost += 1
                if examples.count < 12 {
                    examples.append("  \(clip.id.prefix(8))\n    \(String(format: "%.1f", recorded))s: …\(a.suffix(90))\n    \(String(format: "%.1f", recorded - cut))s: …\(b.suffix(90))")
                }
            }
            print(String(format: "  %@ sound in cut tail · %@", String(clip.id.prefix(8)),
                         BenchSupport.lostEnding(early: b, today: a) ? "✗ LOST ENDING" : "ok"))
        }
        let total = silent + withSound
        print(String(format: "\n=== %.1fs capture vs %.1fs ===", recorded - cut, recorded))
        print(String(format: "clips: %d · last %.1fs is true silence in %d (%.0f%%) → can't lose anything",
                     total, cut, silent, Double(silent) / Double(max(total, 1)) * 100))
        print(String(format: "sound in the cut stretch: %d (%.0f%%) · text changed in %d · LOST ENDING in %d (%.1f%% of all clips)",
                     withSound, Double(withSound) / Double(max(total, 1)) * 100, changed, lost,
                     Double(lost) / Double(max(total, 1)) * 100))
        print("controls (silent tail, decoded both ways): \(controlChanged) of \(controlRuns) changed text")
        if !examples.isEmpty { print("\nlost-ending examples:\n" + examples.joined(separator: "\n")) }
        return 0
    }

    /// The release path's own decode: silence trim, then transcribeSamples.
    static func decode(_ samples: [Float], model: String) async -> String {
        let voiced = TranscriptionModel.trimSilence(samples)
        guard voiced.count > 16_000 / 3 else { return "" }
        return await TranscriptionModel.shared.transcribeSamples(Array(voiced), model: model) ?? ""
    }

    /// Whether the last `cutSamples` hold only room noise: every 10ms frame
    /// ≤ max(1.5 × the clip's 10th-percentile frame RMS, 0.5 × trim threshold).
    static func isSilentTail(_ samples: [Float], cutSamples: Int) -> Bool {
        let frame = 160, frames = samples.count / frame
        guard frames > 0 else { return true }
        var rms = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for j in (f * frame)..<(f * frame + frame) { sum += samples[j] * samples[j] }
            rms[f] = (sum / Float(frame)).squareRoot()
        }
        let threshold = TranscriptionModel.edgeThreshold(frameRMS: rms)
        let sorted = rms.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 10)]
        let silence = max(1.5 * floor, 0.5 * threshold)
        let tailFrames = cutSamples / frame
        return !rms.suffix(tailFrames).contains { $0 > silence }
    }
}
