import Foundation

/// `Slive --bench-dump` — Whisper's side of a model comparison: for labelled
/// training clips (stratified by length), the app's exact decode path
/// (silence trim → transcribeSamples) with its warm decode time, plus each
/// clip's path, trimmed span and Should-be label, one JSON line per clip.
/// Other engines (e.g. Parakeet) replay the same trimmed spans.
///
/// Flags: --out <jsonl> · --limit <n> (120) · --model <id>.
@MainActor
enum DumpBench {
    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let model = value("--model") ?? "large-v3-v20240930_626MB"
        let limit = Int(value("--limit") ?? "") ?? 120
        guard let outPath = value("--out") else { print("✗ --out required"); return 2 }
        let whisper = TranscriptionModel.shared
        guard await whisper.ensureLoaded(model) else { print("✗ model not available"); return 2 }
        if let speech = TranscriptionModel.warmUpAudio { _ = await whisper.transcribeSamples(speech, model: model) }

        FileManager.default.createFile(atPath: outPath, contents: nil)
        guard let out = FileHandle(forWritingAtPath: outPath) else { return 2 }
        let clips = BenchSupport.loadClips(minSeconds: 1, limit: limit, labeledOnly: true)
        for (i, clip) in clips.enumerated() {
            guard let samples = BenchSupport.readWAV(clip.url) else { continue }
            let voiced = TranscriptionModel.trimSilence(samples)
            guard voiced.count > 16_000 / 3 else { continue }
            let t = Date()
            let text = await whisper.transcribeSamples(Array(voiced), model: model) ?? ""
            let row: [String: Any] = [
                "id": clip.id, "path": clip.url.path,
                "trimStart": voiced.startIndex, "trimEnd": voiced.endIndex,
                "seconds": Double(voiced.count) / 16_000,
                "reference": clip.reference ?? "", "whisper": text,
                "whisperSeconds": Date().timeIntervalSince(t),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: row) {
                out.write(data); out.write(Data("\n".utf8))
            }
            if (i + 1) % 20 == 0 { print("  \(i + 1)/\(clips.count)") }
        }
        try? out.close()
        print("✓ wrote \(outPath)")
        return 0
    }
}
