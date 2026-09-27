import CoreML
import Foundation
import WhisperKit

/// `Slive --bench-compute` — where does a dictation's decode time go, and
/// would a different chip run a stage faster on this Mac?
///
/// Loads the model once per compute layout (encoder / decoder on the Neural
/// Engine, GPU or CPU), decodes the same captured clips with the app's exact
/// decode options, and prints WhisperKit's own per-stage timings.
///
/// Flags: --model <id> · --limit <n clips> (default 24).
/// Dev tool only — loads a second copy of the model per layout, one at a time.
@MainActor
enum ComputeBench {
    struct Layout {
        let name: String
        let encoder: MLComputeUnits
        let decoder: MLComputeUnits
        var mel: MLComputeUnits = .cpuAndGPU   // WhisperKit's default
    }

    static let layouts = [
        Layout(name: "ANE enc + ANE dec (today)", encoder: .cpuAndNeuralEngine, decoder: .cpuAndNeuralEngine),
        Layout(name: "ANE enc + GPU dec", encoder: .cpuAndNeuralEngine, decoder: .cpuAndGPU),
        Layout(name: "GPU enc + GPU dec", encoder: .cpuAndGPU, decoder: .cpuAndGPU),
        Layout(name: "ANE enc + CPU dec", encoder: .cpuAndNeuralEngine, decoder: .cpuOnly),
        Layout(name: "ANE enc + ANE dec, mel on CPU", encoder: .cpuAndNeuralEngine,
               decoder: .cpuAndNeuralEngine, mel: .cpuOnly),
    ]

    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let model = value("--model") ?? "large-v3-v20240930_626MB"
        let limit = Int(value("--limit") ?? "") ?? 24
        let maxSeconds = Double(value("--max-seconds") ?? "") ?? 1e9
        let perClip = args.contains("--per-clip")
        let chosen = args.contains("--mel-only") ? [layouts[0], layouts[4]]
            : args.contains("--ane-only") ? Array(layouts.prefix(1)) : layouts
        let clips = BenchSupport.loadClips(minSeconds: 1, limit: limit)
            .compactMap { BenchSupport.readWAV($0.url) }
            .map { Array(TranscriptionModel.trimSilence($0)) }
            .filter { $0.count > 16_000 / 3 && Double($0.count) / 16_000 <= maxSeconds }
        let audio = clips.map { Double($0.count) / 16_000 }.reduce(0, +)
        print(String(format: "%d clips, %.0fs of speech · model %@", clips.count, audio, model))
        let options = TranscriptionModel.shared.decodeOptions(chunking: true)

        for layout in chosen {
            let compute = ModelComputeOptions(melCompute: layout.mel,
                                              audioEncoderCompute: layout.encoder,
                                              textDecoderCompute: layout.decoder)
            let basket = TranscriptionModel.shared.basket
            let root = basket.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            guard let folder = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .first(where: { $0.lastPathComponent.hasSuffix(model) }) else {
                print("✗ model folder for \(model) not found under \(root.path)"); return 2
            }
            let config = WhisperKitConfig(model: model, modelFolder: folder.path,
                                          tokenizerFolder: basket,
                                          computeOptions: compute,
                                          prewarm: false, load: true, download: false)
            let t0 = Date()
            let kit: WhisperKit
            do { kit = try await WhisperKit(config) } catch {
                print("\n\(layout.name): ✗ failed to load — \(error)"); continue
            }
            let load = Date().timeIntervalSince(t0)
            _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: 16_000), decodeOptions: options)

            var walls: [Double] = []
            var sum = TranscriptionTimings()
            var tokens = 0.0
            for clip in clips {
                let t = Date()
                guard let results = try? await kit.transcribe(audioArray: clip, decodeOptions: options) else { continue }
                walls.append(Date().timeIntervalSince(t))
                if perClip, let x = results.first?.timings, results.count == 1 {
                    print(String(format: "  %5.1fs audio · wall %.3fs · encoder %.3fs · %3.0f tokens × %.1fms model + %.1fms CPU",
                                 Double(clip.count) / 16_000, walls.last!, x.encoding, x.totalDecodingLoops,
                                 x.decodingPredictions / max(x.totalDecodingLoops, 1) * 1000,
                                 (x.decodingSampling + x.decodingKvCaching + x.decodingNonPrediction)
                                    / max(x.totalDecodingLoops, 1) * 1000))
                }
                for r in results {
                    let x = r.timings
                    sum.logmels += x.logmels; sum.encoding += x.encoding; sum.prefill += x.prefill
                    sum.decodingLoop += x.decodingLoop; sum.decodingPredictions += x.decodingPredictions
                    sum.decodingSampling += x.decodingSampling; sum.decodingKvCaching += x.decodingKvCaching
                    sum.decodingNonPrediction += x.decodingNonPrediction
                    tokens += x.totalDecodingLoops
                }
            }
            let n = Double(max(walls.count, 1))
            let sorted = walls.sorted()
            print("\n\(layout.name)  (load \(String(format: "%.1f", load))s)")
            print(String(format: "  per clip: median %.3fs · p90 %.3fs · mean %.3fs",
                         sorted.isEmpty ? .nan : sorted[sorted.count / 2],
                         sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))],
                         walls.reduce(0, +) / n))
            print(String(format: "  stage means (s): mel %.3f · ENCODER %.3f · prefill %.3f · decode loop %.3f",
                         sum.logmels / n, sum.encoding / n, sum.prefill / n, sum.decodingLoop / n))
            print(String(format: "    inside decode loop: model predictions %.3f · CPU-side (sampling+kv+other) %.3f · %.0f tokens/clip · %.1f ms/token",
                         sum.decodingPredictions / n,
                         (sum.decodingSampling + sum.decodingKvCaching + sum.decodingNonPrediction) / n,
                         tokens / n, sum.decodingLoop / max(tokens, 1) * 1000))
        }
        return 0
    }
}
