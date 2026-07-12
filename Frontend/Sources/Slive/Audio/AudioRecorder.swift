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

    /// Whether the input node currently has the system voice-processing chain
    /// (echo cancellation) attached — tracked so we only toggle on change.
    private var voiceProcessingOn = false

    /// Attach/detach the system voice-processing chain (the FaceTime echo
    /// canceller) per the setting. With speakers instead of headphones, the mic
    /// hears whatever the Mac is playing — music, videos — and transcription
    /// quality collapses; AEC subtracts the known output signal from the mic.
    /// Must be called while the engine is stopped (we're between recordings).
    private func applyVoiceProcessing(_ input: AVAudioInputNode) {
        let want = Settings.shared.echoCancellation
        guard want != voiceProcessingOn else { return }
        do {
            try input.setVoiceProcessingEnabled(want)
            voiceProcessingOn = want
            if want {
                // Don't audibly duck the user's music while they dictate — we
                // only need the cancellation, not the FaceTime-style volume dip.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false, duckingLevel: .min)
            }
            Log.app("voice processing (echo cancellation) \(want ? "on" : "off")")
        } catch {
            NSLog("Slive: voice processing toggle failed — recording without AEC: \(error)")
        }
    }

    /// Begin recording. Returns false if the engine failed to start.
    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }

        let input = engine.inputNode
        // Attach AEC BEFORE reading the format — voice processing changes the
        // node's output format, and the tap + WAV must match what it produces.
        applyVoiceProcessing(input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("Slive: invalid input format (mic not ready)")
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
            NSLog("Slive: could not open temp file: \(error)")
            return false
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("Slive: engine start failed: \(error)")
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
