import AVFoundation
import Foundation
import SliveObjC

/// Echo cancellation: `AVAudioEngine` with the system voice-processing
/// chain. AEC needs the output reference signal, so this path follows the
/// system default route; the mic pick is not applied.
///
/// Delivers buffers in the canonical format (16 kHz mono Float32), or the
/// node's native format when no converter can be built for it.
///
/// Threading: main thread, except `handle(_:)` (the engine's tap — AUDIO
/// THREAD).
final class VoiceProcessingSource: AudioSource {
    private let engine = AVAudioEngine()
    private var running = false
    private var configObserver: NSObjectProtocol?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Everything is recorded in this canonical format — 16 kHz mono Float32,
    /// what Whisper actually consumes — regardless of what the hardware hands
    /// us. The input node's format is a moving target (voice processing flips
    /// it to a multichannel voice-chat mode: 7ch/48k in practice), and writing
    /// the node's format verbatim produced WAVs the transcriber choked on.
    /// Converting in the tap decouples the file from the device forever.
    private let targetFormat = MicCapture.canonicalFormat
    /// Live converter from the engine node's format to `targetFormat` (nil →
    /// buffers are already canonical, or fall back to the native format).
    private var converter: AVAudioConverter?
    /// The format this recording's buffers are delivered in.
    private var outputFormat: AVAudioFormat?
    private var loggedConversionError = false

    /// Reused conversion output buffer — GROW-ONLY. A fixed capacity would
    /// silently truncate audio if a device change raised the resample ratio
    /// (the converter clamps at frameCapacity without reporting an error);
    /// growing when a callback needs more can never lose samples. Reusing it
    /// removes a heap allocation per tap callback from the audio thread.
    private var convertBuffer: AVAudioPCMBuffer?

    /// Whether the input node currently has the system voice-processing chain
    /// (echo cancellation) attached — tracked so we only toggle on change.
    private var voiceProcessingOn = false

    init() {
        // A device change — AirPods connecting, headphones un/plugged, a
        // sample-rate switch — makes AVAudioEngine reconfigure: the engine
        // STOPS and the input node's format may be different afterwards.
        // Rewire the capture path with the freshly-read format; the WAV
        // survives the switch because it's written in the canonical format,
        // not the device's.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: AudioSource

    /// Configure the engine's input for this recording and return the format
    /// buffers will be delivered in (nil = mic not usable).
    func prepare(_ options: CaptureOptions) -> AVAudioFormat? {
        loggedConversionError = false
        let input = engine.inputNode
        // Attach AEC BEFORE reading the format — voice processing changes the
        // node's output format, and the tap + WAV must match what it produces.
        applyVoiceProcessing(input, want: options.echoCancellation)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("Slive: invalid input format (mic not ready)")
            return nil
        }
        // Convert to the canonical format in the tap; if the converter can't be
        // built (exotic device format) fall back to writing the native format.
        // Converter is REUSED across holds (rebuilt only on a format change).
        if let conv = converter, conv.inputFormat.isEqual(format) {
            conv.reset()   // drop resampler state from the previous session
        } else {
            converter = AVAudioConverter(from: format, to: targetFormat)
            if converter == nil {
                NSLog("Slive: no converter for \(format) — recording in native format")
            }
        }
        let output = converter != nil ? targetFormat : format
        outputFormat = output
        return output
    }

    func start(_ options: CaptureOptions,
               onAudioThreadBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        onBuffer = onAudioThreadBuffer
        let input = engine.inputNode
        if let reason = installCaptureTap(on: input) {
            NSLog("Slive: mic tap refused: \(reason) — node \(input.outputFormat(forBus: 0)), hardware \(input.inputFormat(forBus: 0))")
            return false
        }
        // Starting the engine can also raise (not just throw) when the
        // device state is inconsistent — same shim, same graceful failure.
        var startError: Error?
        let startRaise = SliveCatchObjCException {
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if startRaise != nil || startError != nil {
            NSLog("Slive: engine start failed: \(startRaise ?? "\(startError!)")")
            input.removeTap(onBus: 0)
            return false
        }
        running = true
        return true
    }

    func stop() {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFormat = nil
    }

    /// Pre-arm for the NEXT hold: prepare() re-allocates the render resources
    /// now, off the hot path.
    func rearm() {
        engine.prepare()
    }

    // MARK: Engine

    private func handleConfigurationChange() {
        guard running else { return }   // next start() reads fresh state anyway
        NSLog("Slive: audio device configuration changed mid-recording — rewiring capture")
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("Slive: input invalid after device change — recording will end at release")
            return
        }
        converter = AVAudioConverter(from: format, to: outputFormat ?? targetFormat)
        if let reason = installCaptureTap(on: input) {
            NSLog("Slive: could not re-tap after device change — recording will end at release: \(reason)")
            return
        }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    /// Install the engine's capture tap so that AVFAudio's assertions can't
    /// abort the process. Returns nil on success, otherwise the reason.
    ///
    /// The tap format is deliberately `nil` (= the node's own output format).
    /// Handing AVAudioEngine an explicit format makes it assert
    /// `format.sampleRate == inputHWFormat.sampleRate` — and the node's
    /// reported output format and the hardware rate DO diverge (the voice-
    /// processing chain, a Bluetooth mic, a post-wake device switch), which
    /// used to SIGABRT the app on key-down. With nil the engine uses whatever
    /// the node really produces; `handle(_:)` canonicalizes from the
    /// buffer's own format, so nothing downstream depends on the tap format.
    /// Any raise that still slips through is caught by the Objective-C shim.
    private func installCaptureTap(on input: AVAudioInputNode) -> String? {
        input.removeTap(onBus: 0)   // harmless when none is installed
        return SliveCatchObjCException {
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                self?.handle(buffer)
            }
        }
    }

    /// Attach/detach the system voice-processing chain (the FaceTime echo
    /// canceller) per the setting. With speakers instead of headphones, the mic
    /// hears whatever the Mac is playing — music, videos — and transcription
    /// quality collapses; AEC subtracts the known output signal from the mic.
    /// Must be called while the engine is stopped (we're between recordings).
    private func applyVoiceProcessing(_ input: AVAudioInputNode, want: Bool) {
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

    // MARK: Audio thread

    /// The tap: canonicalize (downmix + resample) before anything touches the
    /// data, then hand off.
    private func handle(_ buffer: AVAudioPCMBuffer) {
        let out: AVAudioPCMBuffer
        if buffer.format.sampleRate == targetFormat.sampleRate, buffer.format.channelCount == 1 {
            out = buffer   // already canonical
        } else if let conv = currentConverter(for: buffer.format) {
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let needed = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            if convertBuffer == nil || convertBuffer!.frameCapacity < needed {
                // Grow-only: first callback, or a device change raised the ratio.
                convertBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                 frameCapacity: max(needed, 2048))
            }
            guard let converted = convertBuffer else { return }
            converted.frameLength = 0
            var fed = false
            var convError: NSError?
            conv.convert(to: converted, error: &convError) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let convError, !loggedConversionError {
                loggedConversionError = true
                NSLog("Slive: audio conversion failed: \(convError)")
            }
            out = converted
        } else {
            out = buffer   // native-format fallback
        }
        onBuffer?(out)
    }

    /// The converter, rebuilt the moment the buffer format stops matching:
    /// the configuration-change notification can lag the actual device switch
    /// by a few buffers — the buffer's own format is the only ground truth.
    private func currentConverter(for format: AVAudioFormat) -> AVAudioConverter? {
        if let conv = converter, !conv.inputFormat.isEqual(format) {
            converter = AVAudioConverter(from: format, to: conv.outputFormat)
        }
        return converter
    }
}
