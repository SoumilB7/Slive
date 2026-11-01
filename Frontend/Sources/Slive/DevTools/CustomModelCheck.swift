import Foundation
import WhisperKit

/// `Slive --custom-model-check <installed model folder>` — proves a trained
/// model the backend installed actually serves: reads its manifest through
/// the real registry (`CustomWhisperModelRegistry.model(in:)`), loads it with
/// the SAME WhisperKit config dictation uses (ANE encoder/decoder, CPU mel,
/// no downloads), checks the tokenizer resolved locally, then transcribes
/// labelled clips on the app path (trimSilence → app decode options) next to
/// the stock Balanced model and prints WER + latency for both.
///
/// Flags: --ids <file> (one clip id per line — e.g. a training run's held-out
/// split; default: --clips N labelled clips) · --clips N (default 40).
@MainActor
enum CustomModelCheck {
    static let stock = "large-v3-v20240930_626MB"

    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--custom-model-check") else {
            print("usage: Slive --custom-model-check <model folder> [--ids file | --clips N]"); return 2
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard let custom = CustomWhisperModelRegistry.model(in: folder) else {
            print("✗ \(path): no readable manifest.json, or a model file is missing "
                  + "(needs AudioEncoder, TextDecoder, MelSpectrogram .mlmodelc)")
            return 1
        }
        print("manifest ok: \(custom.id) (base \(custom.baseModel))")

        // WhisperKit 0.9.4 resolves a local tokenizer at
        // <tokenizerFolder>/models/<repo>/tokenizer.json — anything else falls
        // back to a Hugging Face download.
        let local = (try? FileManager.default.subpathsOfDirectory(atPath: custom.tokenizerFolder.path))?
            .filter { $0.hasPrefix("models/") && $0.hasSuffix("/tokenizer.json") } ?? []
        guard !local.isEmpty else {
            print("✗ no models/<repo>/tokenizer.json under \(custom.tokenizerFolder.path) "
                  + "— WhisperKit would download the tokenizer")
            return 1
        }
        print("tokenizer: \(local.joined(separator: ", "))")

        let clips = selectClips(ids: value("--ids"), limit: Int(value("--clips") ?? "") ?? 40)
        guard !clips.isEmpty else { print("✗ no labelled clips matched"); return 2 }
        print("clips: \(clips.count)")

        let compute = ModelComputeOptions(melCompute: .cpuOnly)
        let basket = TranscriptionModel.shared.basket
        let stockFolder = basket.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/openai_whisper-\(stock)")
        let configs = [
            ("custom", WhisperKitConfig(model: custom.id, modelFolder: custom.modelFolder.path,
                                        tokenizerFolder: custom.tokenizerFolder, computeOptions: compute,
                                        prewarm: false, load: false, download: false)),
            ("stock ", WhisperKitConfig(model: stock, modelFolder: stockFolder.path,
                                        tokenizerFolder: basket, computeOptions: compute,
                                        prewarm: false, load: false, download: false)),
        ]
        var outputs: [String: [String]] = [:]
        for (label, config) in configs {
            do {
                var t = Date()
                let kit = try await WhisperKit(config)
                try await kit.loadModels()
                let load = Date().timeIntervalSince(t)
                guard kit.tokenizer != nil else { print("✗ \(label): no tokenizer"); return 1 }
                let options = TranscriptionModel.shared.decodeOptions(chunking: true)
                var texts: [String] = []
                var decode = 0.0, errors = 0.0, words = 0.0
                for clip in clips {
                    guard let audio = BenchSupport.readWAV(clip.url) else { texts.append(""); continue }
                    let voiced = Array(TranscriptionModel.trimSilence(audio))
                    t = Date()
                    let results = try await kit.transcribe(audioArray: voiced, decodeOptions: options)
                    decode += Date().timeIntervalSince(t)
                    let text = TranscriptionModel.cleanStreamText(results.map(\.text).joined())
                    texts.append(text)
                    let n = Double(BenchSupport.words(clip.reference ?? "").count)
                    errors += BenchSupport.wer(text, clip.reference ?? "") * n
                    words += n
                }
                outputs[label] = texts
                print(String(format: "%@ · load %.1fs · WER %.2f%% · %.0f ms/clip",
                             label, load, 100 * errors / max(words, 1),
                             1000 * decode / Double(clips.count)))
            } catch {
                print("✗ \(label): \(error)")
                return 1
            }
        }
        if let a = outputs["custom"], let b = outputs["stock "] {
            let differing = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }
            print("differs from stock on \(differing.count)/\(clips.count) clips")
            for (i, pair) in differing.prefix(5) {
                print("  ref:    \(clips[i].reference ?? "")\n  stock:  \(pair.1)\n  custom: \(pair.0)")
            }
        }
        return 0
    }

    private static func selectClips(ids path: String?, limit: Int) -> [BenchSupport.Clip] {
        let all = BenchSupport.loadClips(minSeconds: 0, limit: 1_000_000, labeledOnly: true)
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return Array(all.prefix(limit))
        }
        let wanted = Set(text.split(whereSeparator: \.isNewline).map(String.init))
        return all.filter { wanted.contains($0.id) }
    }
}
