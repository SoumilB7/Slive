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

    /// Everything is recorded in this canonical format — 16 kHz mono Float32,
    /// what Whisper actually consumes — regardless of what the hardware hands
    /// us. The input node's format is a moving target (voice processing flips
    /// it to a multichannel voice-chat mode: 7ch/48k in practice), and writing
    /// the node's format verbatim produced WAVs the transcriber choked on.
    /// Converting in the tap decouples the file from the device forever.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// Live converter from the node's current format to `targetFormat` (nil →
    /// fall back to writing the native format, the pre-conversion behavior).
    private var converter: AVAudioConverter?
    /// The format the current WAV was opened with (the converter's output side).
    private var fileFormat: AVAudioFormat?
    private var loggedWriteError = false
    private var configObserver: NSObjectProtocol?

    init() {
        // A device change — AirPods connecting, headphones un/plugged, a
        // sample-rate switch — makes AVAudioEngine reconfigure: the engine
        // STOPS and the input node's format may be different afterwards.
        // Without handling this, a recording that spans the change dies
        // silently (dead tap or format-mismatched writes). Rewire the capture
        // path with the freshly-read format; the WAV survives the switch
        // because it's written in the canonical format, not the device's.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func handleConfigurationChange() {
        guard isRecording else { return }   // next start() reads fresh state anyway
        NSLog("Slive: audio device configuration changed mid-recording — rewiring capture")
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("Slive: input invalid after device change — recording will end at release")
            return
        }
        converter = AVAudioConverter(from: format, to: fileFormat ?? targetFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

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

        // Convert to the canonical format in the tap; if the converter can't be
        // built (exotic device format) fall back to writing the native format.
        converter = AVAudioConverter(from: format, to: targetFormat)
        if converter == nil {
            NSLog("Slive: no converter for \(format) — recording in native format")
        }
        let fileFormat = converter != nil ? targetFormat : format
        self.fileFormat = fileFormat
        fft = FFTProcessor(fftSize: 1024, bandCount: bandCount, sampleRate: fileFormat.sampleRate)
        loggedWriteError = false

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowy-\(UUID().uuidString).wav")
        do {
            file = try AVAudioFile(forWriting: tmp, settings: fileFormat.settings)
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
        fileFormat = nil
        startTime = nil
        // Nudge the meters back to rest.
        DispatchQueue.main.async { [weak self] in
            self?.onLevels?([Float](repeating: 0, count: self?.bandCount ?? 28), 0)
        }
        return url
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        // The notification can lag the actual device switch by a few buffers —
        // the buffer's own format is the only ground truth. Rebuild the
        // converter the moment it stops matching.
        if let conv = converter, !conv.inputFormat.isEqual(buffer.format) {
            converter = AVAudioConverter(from: buffer.format, to: conv.outputFormat)
        }
        // Canonicalize (downmix + resample) before anything touches the data.
        let out: AVAudioPCMBuffer
        if let conv = converter {
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            conv.convert(to: converted, error: &convError) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let convError, !loggedWriteError {
                loggedWriteError = true
                NSLog("Slive: audio conversion failed: \(convError)")
            }
            out = converted
        } else {
            out = buffer
        }

        if let file = file {
            do { try file.write(from: out) } catch {
                // A silent write failure here is how recordings break invisibly
                // — say so once per recording.
                if !loggedWriteError {
                    loggedWriteError = true
                    NSLog("Slive: WAV write failed: \(error)")
                }
            }
        }

        guard let channelData = out.floatChannelData else { return }
        let frames = Int(out.frameLength)
        guard frames > 0 else { return }

        // Mono channel 0 of the canonical buffer feeds the meters.
        let mono = Array(UnsafeBufferPointer(start: channelData[0], count: frames))

        let bands = fft?.process(mono) ?? []
        let rms = FFTProcessor.rms(mono)

        DispatchQueue.main.async { [weak self] in
            self?.onLevels?(bands, rms)
        }
    }
}
