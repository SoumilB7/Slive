import Foundation

/// `Slive --bench-coldstart` — the first-dictations-after-install problem.
///
/// Run it from the app bundle (`Slive.app/Contents/MacOS/Slive --bench-coldstart`)
/// so it shares com.slive.app's Neural Engine compile cache; run it right
/// after a fresh build to reproduce the post-install state. Measures time
/// to model-ready, then decodes the first clips back to back (what a new
/// user's first dictations hit), then re-decodes clip #1 fully warm.
///
/// Flags: --warmup none|silence|bundled|speech (silence = the old 0.5s warm-up;
/// bundled = the app's WarmUp.wav; speech = one of your clips) · --clips <n> (6) · --model <id>.
@MainActor
enum ColdStartBench {
    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let t0 = Date()
        let model = value("--model") ?? "large-v3-v20240930_626MB"
        if let from = value("--redecode-since"), let to = value("--until") {
            return await redecode(from: from, to: to, model: model)
        }
        let warmup = value("--warmup") ?? "silence"
        let count = Int(value("--clips") ?? "") ?? 6
        TranscriptionModel.benchSuppressesAutoWarm = true
        let whisper = TranscriptionModel.shared

        // Real clips, 3–15s, oldest-first so the "speech" warm-up clip is
        // never one of the measured ones.
        let pool = BenchSupport.loadClips(minSeconds: 3, limit: 400)
            .compactMap { BenchSupport.readWAV($0.url) }
            .filter { Double($0.count) / 16_000 <= 15 }
        guard pool.count > count + 1 else { print("✗ not enough clips"); return 2 }
        let warmClip = pool[pool.count - 1]
        let clips = Array(pool.prefix(count))
        print(String(format: "bundle: %@ · warm-up: %@", Bundle.main.bundleIdentifier ?? "(none)", warmup))

        guard await whisper.ensureLoaded(model) else { print("✗ model not available"); return 2 }
        print(String(format: "model ready %.2fs after launch", Date().timeIntervalSince(t0)))

        var t = Date()
        switch warmup {
        case "silence":
            _ = await whisper.transcribeSamples([Float](repeating: 0, count: 8_000), model: model)
        case "bundled":
            guard let clip = TranscriptionModel.warmUpAudio else { print("✗ no bundled WarmUp.wav"); return 2 }
            _ = await whisper.transcribeSamples(clip, model: model)
        case "speech":
            _ = await whisper.transcribeSamples(Array(TranscriptionModel.trimSilence(warmClip)), model: model)
        default: break
        }
        if warmup != "none" { print(String(format: "warm-up took %.2fs", Date().timeIntervalSince(t))) }

        for (i, clip) in clips.enumerated() {
            let voiced = Array(TranscriptionModel.trimSilence(clip))
            t = Date()
            let text = await whisper.transcribeSamples(voiced, model: model) ?? ""
            print(String(format: "dictation #%d  %4.1fs audio → %.2fs  «%@»", i + 1,
                         Double(voiced.count) / 16_000, Date().timeIntervalSince(t),
                         String(text.prefix(50))))
        }
        let first = Array(TranscriptionModel.trimSilence(clips[0]))
        t = Date()
        let again = await whisper.transcribeSamples(first, model: model) ?? ""
        print(String(format: "dictation #1 again (fully warm) → %.2fs  «%@»",
                     Date().timeIntervalSince(t), String(again.prefix(50))))
        return 0
    }

    /// Re-transcribe the clips captured in [from, to] (ISO timestamps) with
    /// a warm model and print what was typed then vs what decodes now.
    static func redecode(from: String, to: String, model: String) async -> Int32 {
        let whisper = TranscriptionModel.shared
        guard await whisper.ensureLoaded(model) else { return 2 }
        _ = await whisper.transcribeSamples(Array(BenchSupport.loadClips(minSeconds: 3, limit: 12).first.flatMap { BenchSupport.readWAV($0.url) } ?? []), model: model)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Slive/training")
        guard let text = try? String(contentsOf: dir.appendingPathComponent("samples.jsonl"), encoding: .utf8) else { return 2 }
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let at = o["createdAt"] as? String, at >= from, at <= to,
                  let rel = o["audioFile"] as? String,
                  let samples = BenchSupport.readWAV(dir.appendingPathComponent(rel)) else { continue }
            let now = await whisper.transcribeSamples(Array(TranscriptionModel.trimSilence(samples)), model: model) ?? ""
            print("\(at)  \(String(format: "%.1f", Double(samples.count) / 16_000))s")
            print("   typed then: \((o["transcript"] as? String) ?? "")")
            print("   warm now  : \(now)")
        }
        return 0
    }
}
