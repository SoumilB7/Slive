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
        if let n = Int(value("--trim-diff") ?? "") {
            return await trimDiff(recent: n, model: model)
        }
        if let id = value("--decode-clip") {
            return await decodeClip(idPrefix: id, model: model)
        }
        if args.contains("--waiting-dictation") {
            return await waitingDictation(model: model)
        }
        if args.contains("--concurrent") {
            return await concurrentWithWarmUp(model: model, rounds: Int(value("--rounds") ?? "") ?? 4)
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

    /// Reproduce the "first dictation after launch comes back empty" bug: a
    /// dictation waiting on the load resumes at the same instant the
    /// post-load warm-up starts — two decodes on ONE WhisperKit instance.
    /// Each round reloads nothing; it fires the warm-up decode and a real
    /// clip's file-path decode (the app's fallback path) concurrently, then
    /// the clip alone, and compares.
    static func concurrentWithWarmUp(model: String, rounds: Int) async -> Int32 {
        TranscriptionModel.benchSuppressesAutoWarm = true
        let whisper = TranscriptionModel.shared
        guard await whisper.ensureLoaded(model) else { print("✗ model"); return 2 }
        guard let warm = TranscriptionModel.warmUpAudio ?? EngineCheck.readInt16WAV(URL(fileURLWithPath: "Resources/WarmUp.wav")),
              let clip = BenchSupport.loadClips(minSeconds: 3, limit: 12).first else { print("✗ audio"); return 2 }
        let alone = await whisper.transcribe(clip.url, model: model) ?? "(nil)"
        print("clip alone: «\(alone.prefix(80))»")
        for round in 1...rounds {
            async let w = whisper.transcribeSamples(warm, model: model)
            async let d = whisper.transcribe(clip.url, model: model)
            let (warmText, clipText) = await (w, d)
            print("round \(round): clip «\((clipText ?? "(nil)").prefix(80))»  ·  warm-up «\((warmText ?? "(nil)").prefix(40))»")
        }
        return 0
    }

    /// The exact launch sequence: the app selects the model (background load,
    /// auto warm-up ON as in the app), and a dictation released immediately
    /// takes the app's path — transcribeSamples (nil: not resident) → file
    /// fallback, which joins the load and decodes when it's ready.
    static func waitingDictation(model: String) async -> Int32 {
        let whisper = TranscriptionModel.shared
        guard let clip = BenchSupport.loadClips(minSeconds: 3, limit: 12).first,
              let samples = BenchSupport.readWAV(clip.url) else { print("✗ audio"); return 2 }
        let t0 = Date()
        whisper.select(model)                         // app launch: background load
        let voiced = Array(TranscriptionModel.trimSilence(samples))
        // The app's path since Oct 7: wait for the model (no racing warm-up),
        // then the normal in-memory decode.
        let wasReady = whisper.isReady(model)
        _ = await whisper.awaitReady(model)
        let text = await whisper.transcribeSamples(voiced, model: model)
        let viaSamples = !wasReady
        print(String(format: "waiting dictation → %.2fs  waited=%@  «%@»", Date().timeIntervalSince(t0),
                     viaSamples ? "yes" : "no", (text ?? "(nil)").isEmpty ? "(EMPTY)" : String((text ?? "(nil)").prefix(70))))
        return 0
    }

    /// One captured clip, decoded several ways on the real model: the app's
    /// path (silence-trimmed), the untrimmed clip, and its pieces — to see
    /// which words exist in the audio but not in what was typed.
    /// Old end edge (= start threshold) vs the soft tail: decode every recent
    /// clip whose trim differs, printing both texts verbatim (case + punctuation).
    static func trimDiff(recent n: Int, model: String) async -> Int32 {
        let whisper = TranscriptionModel.shared
        guard await whisper.ensureLoaded(model) else { print("✗ model"); return 2 }
        let clips = BenchSupport.loadClips(minSeconds: 0, limit: n, since: "2000-01-01")
        var changed = 0, styleChanged = 0
        for clip in clips {
            guard let samples = BenchSupport.readWAV(clip.url) else { continue }
            let new = TranscriptionModel.trimSilence(samples)
            let frames = samples.count / 160
            guard frames > 0 else { continue }
            let rms = (0..<frames).map { f -> Float in
                var sum: Float = 0
                for j in (f * 160)..<(f * 160 + 160) { sum += samples[j] * samples[j] }
                return (sum / 160).squareRoot()
            }
            let threshold = TranscriptionModel.edgeThreshold(frameRMS: rms)
            guard let last = rms.lastIndex(where: { $0 > threshold }) else { continue }
            let oldEnd = min(samples.count, (last + 1) * 160 + TranscriptionModel.trimTailPad)
            guard oldEnd != new.endIndex else { continue }
            changed += 1
            let old = Array(samples[new.startIndex..<oldEnd])
            let a = await whisper.transcribeSamples(old, model: model) ?? ""
            let b = await whisper.transcribeSamples(Array(new), model: model) ?? ""
            let style = (a.first?.isUppercase ?? false) != (b.first?.isUppercase ?? false)
                || a.filter { ".,?!".contains($0) }.count != b.filter { ".,?!".contains($0) }.count
            if style { styleChanged += 1 }
            print("== \(clip.id.prefix(8)) +\(String(format: "%.2f", Double(new.endIndex - oldEnd) / 16_000))s\(style ? "  STYLE" : "")")
            print("  old: «\(a)»\n  new: «\(b)»")
        }
        print("changed \(changed) of \(clips.count), style changed \(styleChanged)")
        return 0
    }

    static func decodeClip(idPrefix: String, model: String) async -> Int32 {
        let whisper = TranscriptionModel.shared
        guard await whisper.ensureLoaded(model) else { print("✗ model"); return 2 }
        guard let clip = BenchSupport.loadClips(minSeconds: 0, limit: 100_000).first(where: { $0.id.hasPrefix(idPrefix) }),
              let samples = BenchSupport.readWAV(clip.url) else { print("✗ clip"); return 2 }
        _ = await whisper.transcribeSamples(Array(samples.prefix(48_000)), model: model)   // warm
        let trimmed = TranscriptionModel.trimSilence(samples)
        func show(_ label: String, _ audio: [Float]) async {
            let t = await whisper.transcribeSamples(audio, model: model) ?? "(nil)"
            print(String(format: "%@ (%.1fs): «%@»", label, Double(audio.count) / 16_000, t))
        }
        await show("APP PATH, trimmed ", Array(trimmed))
        await show("full, untrimmed   ", samples)
        let n = samples.count
        await show("first half        ", Array(samples[0..<n / 2]))
        await show("second half       ", Array(samples[n / 2..<n]))
        await show("last 6s           ", Array(samples[max(0, n - 96_000)..<n]))
        return 0
    }
}
