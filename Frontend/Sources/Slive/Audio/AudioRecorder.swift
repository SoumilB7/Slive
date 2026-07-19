import Accelerate
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

    /// Reused conversion output buffer — GROW-ONLY. A fixed capacity would
    /// silently truncate audio if a device change raised the resample ratio
    /// (the converter clamps at frameCapacity without reporting an error);
    /// growing when a callback needs more can never lose samples. Reusing it
    /// removes a heap allocation per tap callback from the audio thread.
    private var convertBuffer: AVAudioPCMBuffer?

    /// Level-update coalescing: the meters ease at 60fps anyway, so dispatching
    /// every tap callback (~47/s) to the main thread bought nothing. Every 3rd
    /// callback we FFT + dispatch, forwarding the running-MAX RMS across the
    /// window so the adaptive release tail's voice detection keeps per-callback
    /// fidelity (a max can't miss a voiced blip between dispatches).
    private var levelCallbackCount = 0
    private var windowMaxRMS: Float = 0

    /// The session's canonical (16k mono) samples, accumulated in the tap so the
    /// release path can transcribe FROM MEMORY — skipping the WAV close/flush →
    /// reopen → read → (re)parse round-trip (~5-30ms per dictation). The WAV is
    /// still written alongside for training capture. Only filled on the
    /// canonical-converter path (native-format fallback → empty → callers use
    /// the file). Guarded by a lock: the tap thread appends while stop() reads.
    private var sessionSamples: [Float] = []
    private let samplesLock = NSLock()
    /// Last tap callback whose RMS crossed the voice threshold (guarded by
    /// `samplesLock`; written on the tap thread, read from main).
    private var lastVoiceTime: CFAbsoluteTime = 0

    /// Seconds since the tap last heard voice-level audio, at full callback
    /// granularity (~21ms). `.infinity` before any voice this session — a
    /// hold with no speech releases with no tail at all.
    func quietFor() -> TimeInterval {
        samplesLock.lock()
        let t = lastVoiceTime
        samplesLock.unlock()
        guard t > 0 else { return .infinity }
        return CFAbsoluteTimeGetCurrent() - t
    }
    /// FFT is rebuilt only when the analysis rate changes (device switch), not
    /// per hold.
    private var fftRate: Double = 0

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
        samplesLock.lock()
        lastVoiceTime = 0   // fresh session — no stale voice recency
        samplesLock.unlock()

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
        // Converter + FFT are REUSED across holds (rebuilt only on a format
        // change) — building them fresh each hold cost a few ms on key-down.
        if let conv = converter, conv.inputFormat.isEqual(format) {
            conv.reset()   // drop resampler state from the previous session
        } else {
            converter = AVAudioConverter(from: format, to: targetFormat)
            if converter == nil {
                NSLog("Slive: no converter for \(format) — recording in native format")
            }
        }
        let fileFormat = converter != nil ? targetFormat : format
        self.fileFormat = fileFormat
        if fft == nil || fftRate != fileFormat.sampleRate {
            fft = FFTProcessor(fftSize: 1024, bandCount: bandCount, sampleRate: fileFormat.sampleRate)
            fftRate = fileFormat.sampleRate
        }
        loggedWriteError = false
        levelCallbackCount = 0
        windowMaxRMS = 0
        samplesLock.lock()
        sessionSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

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

    /// Stop recording. Returns the finalized WAV URL (nil on failure) plus the
    /// session's canonical in-memory samples (empty on the native-format
    /// fallback path — transcribe from the file then).
    @discardableResult
    func stop() -> (url: URL?, samples: [Float]) {
        guard isRecording else { return (nil, []) }
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
        // Pre-arm for the NEXT hold: prepare() re-allocates the render
        // resources now, off the hot path, so the next engine.start() (key-down
        // → mic live) skips that work.
        engine.prepare()
        samplesLock.lock()
        let samples = sessionSamples
        sessionSamples = []
        samplesLock.unlock()
        return (url, samples)
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

        if converter != nil {   // canonical 16k mono — safe to hand to Whisper
            samplesLock.lock()
            sessionSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frames))
            samplesLock.unlock()
        }

        // RMS every callback (cheap vDSP, no copy) — it feeds voice-activity
        // detection, whose fidelity we keep at full rate via the running max.
        var meanSquare: Float = 0
        vDSP_measqv(channelData[0], 1, &meanSquare, vDSP_Length(frames))
        let instantRMS = sqrtf(meanSquare)
        windowMaxRMS = max(windowMaxRMS, instantRMS)
        // Voice recency at full callback rate (~21ms buffers): the coalesced
        // level dispatch below is fine for visuals but adds up to ~64ms of
        // staleness — the release tail reads THIS instead, so it can end the
        // moment real silence is observed.
        if instantRMS > 0.03 {
            samplesLock.lock()
            lastVoiceTime = CFAbsoluteTimeGetCurrent()
            samplesLock.unlock()
        }

        // FFT + main-thread dispatch only every 3rd callback (~15/s instead of
        // ~47/s): the 60fps easer interpolates the visual identically, and the
        // main thread takes a third of the wakeups.
        levelCallbackCount += 1
        guard levelCallbackCount >= 3 else { return }
        levelCallbackCount = 0
        let rms = windowMaxRMS
        windowMaxRMS = 0

        // Mono channel 0 of the canonical buffer feeds the analyser.
        let mono = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        let bands = fft?.process(mono) ?? []

        DispatchQueue.main.async { [weak self] in
            self?.onLevels?(bands, rms)
        }
    }
}
