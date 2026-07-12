import AVFoundation
import Foundation

/// Captures microphone audio into a temporary WAV file while emitting
/// real-time spectral levels for the visualiser. One instance per app;
/// call `start()` on key-down and `stop()` on key-up.
final class AudioRecorder {
    /// Called on the main thread ~45×/sec with (bands 0...1, rms 0...1).
    var onLevels: (([Float], Float) -> Void)?

    private let engine = AVAudioEngine()
    private var fft: FFTProcessor?
    private var file: AVAudioFile?
    private var tempURL: URL?
    private(set) var isRecording = false
    private(set) var startTime: Date?

    let bandCount = 14

    /// Begin recording. Returns false if the engine failed to start.
    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("Flowy: invalid input format (mic not ready)")
            return false
        }

        fft = FFTProcessor(fftSize: 1024, bandCount: bandCount, sampleRate: format.sampleRate)

        // Temp WAV in the input's native format; lame downsamples later.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowy-\(UUID().uuidString).wav")
        do {
            file = try AVAudioFile(forWriting: tmp, settings: format.settings)
            tempURL = tmp
        } catch {
            NSLog("Flowy: could not open temp file: \(error)")
            return false
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("Flowy: engine start failed: \(error)")
            input.removeTap(onBus: 0)
            file = nil
            return false
        }

        isRecording = true
        startTime = Date()
        return true
    }

    /// Stop recording and return the finalized WAV URL (nil on failure).
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let url = tempURL
        file = nil          // closes the file, flushing the WAV header
        tempURL = nil
        startTime = nil
        // Nudge the meters back to rest.
        DispatchQueue.main.async { [weak self] in
            self?.onLevels?([Float](repeating: 0, count: self?.bandCount ?? 28), 0)
        }
        return url
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        // Persist to disk in the native format.
        if let file = file {
            try? file.write(from: buffer)
        }

        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Downmix to mono (channel 0 is plenty for a level meter).
        let mono = Array(UnsafeBufferPointer(start: channelData[0], count: frames))

        let bands = fft?.process(mono) ?? []
        let rms = FFTProcessor.rms(mono)

        DispatchQueue.main.async { [weak self] in
            self?.onLevels?(bands, rms)
        }
    }
}
