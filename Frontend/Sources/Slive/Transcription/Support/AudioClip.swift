import AVFoundation
import Foundation

enum AudioClip {
    /// Every sample of a 16 kHz mono file, or nil when it isn't one (or
    /// can't be read). Slive's own WAVs are already in that format.
    static func read16kMono(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    /// The file's length in seconds, nil when it can't be opened.
    static func seconds(_ url: URL) -> Double? {
        (try? AVAudioFile(forReading: url)).map { Double($0.length) / max(1, $0.processingFormat.sampleRate) }
    }

    /// Bundled warm-up speech (Resources/WarmUp.wav, 16 kHz mono), or nil
    /// outside the app bundle.
    static let warmUp: [Float]? = Bundle.main.url(forResource: "WarmUp", withExtension: "wav")
        .flatMap(read16kMono)
}
