import AVFoundation
import Foundation

/// `Slive --engine-check` — proves the Parakeet engine is wired: loads each
/// Parakeet model through Slive's own `ParakeetEngine` and transcribes the
/// warm-up clip (known words), timing load, first and warm decodes.
///
/// Flags: --model parakeet-ultra|parakeet-v2 (default: all) · --wav <path>
/// (default: the bundled WarmUp.wav, or Resources/WarmUp.wav from Frontend/).
@MainActor
enum EngineCheck {
    static let warmUpWords = "Slive is warming up the speech model, so your very first dictation feels instant."

    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let audio: [Float]?
        if let path = value("--wav") {
            audio = BenchSupport.readWAV(URL(fileURLWithPath: path))
        } else {
            audio = TranscriptionModel.warmUpAudio
                ?? readInt16WAV(URL(fileURLWithPath: "Resources/WarmUp.wav"))
        }
        guard let audio else { print("✗ no audio (pass --wav, or run from Frontend/)"); return 2 }
        let models = value("--model").flatMap(ParakeetModel.init(rawValue:)).map { [$0] } ?? ParakeetModel.allCases
        print("clip says: «\(warmUpWords)»")
        for model in models {
            do {
                var t = Date()
                let engine = try await ParakeetEngine.load(model)
                let load = Date().timeIntervalSince(t)
                t = Date()
                let first = try await engine.transcribe(audio)
                let firstTime = Date().timeIntervalSince(t)
                t = Date()
                _ = try await engine.transcribe(audio)
                print(String(format: "%@ · load %.1fs · first decode %.3fs · warm %.3fs\n    «%@»",
                             model.displayName, load, firstTime, Date().timeIntervalSince(t), first))
            } catch {
                print("✗ \(model.displayName): \(error)")
            }
        }
        return 0
    }

    /// Dev fallback when not running from the app bundle (WarmUp.wav is Int16).
    static func readInt16WAV(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }
}
