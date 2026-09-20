import Accelerate
import AVFoundation
import Foundation
import SliveObjC

/// Captures microphone audio into a temporary WAV file while emitting
/// real-time spectral levels for the visualiser. One instance per app;
/// call `start()` on key-down and `stop()` on key-up.
///
/// Two capture backends, chosen per recording:
/// - **Direct** (echo cancellation off — the default): `MicCapture`, a raw
///   HAL output unit on exactly the microphone chosen in Settings (or the
///   system default). Opens that device and nothing else — with a Bluetooth
///   headset playing music, picking the built-in mic leaves the headset in
///   A2DP. Buffers arrive already canonical (16 kHz mono).
/// - **Engine** (echo cancellation on): `AVAudioEngine` with the system
///   voice-processing chain. AEC needs the output reference signal, so this
///   path follows the system default route; the mic pick is not applied.
final class AudioRecorder {
    /// Called on the main thread ~45×/sec with (bands 0...1, rms 0...1).
    var onLevels: (([Float], Float) -> Void)?

    private let capture = MicCapture.shared
    private let engine = AVAudioEngine()
    /// Which backend the CURRENT recording runs on.
    private var usingEngine = false
    private var fft: FFTProcessor?
    private var file: AVAudioFile?
    private var tempURL: URL?
    private(set) var isRecording = false
    private(set) var startTime: Date?

    let bandCount = 14

    /// Echo cancellation is the only reason to run the engine.
    static func usesEngine(echoCancellation: Bool) -> Bool { echoCancellation }

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
    /// The format the current WAV was opened with.
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
    /// still written alongside for training capture. Only filled when the
    /// buffers are canonical (native-format fallback → empty → callers use
    /// the file). Guarded by a lock: the audio thread appends while stop() reads.
    private var sessionSamples: [Float] = []
    private let samplesLock = NSLock()
    /// Last callback whose RMS crossed the voice threshold (guarded by
    /// `samplesLock`; written on the audio thread, read from main).
    private var lastVoiceTime: CFAbsoluteTime = 0

    /// Seconds since the mic last heard voice-level audio, at full callback
    /// granularity. `.infinity` before any voice this session — a hold with
    /// no speech releases with no tail at all.
    func quietFor() -> TimeInterval {
        samplesLock.lock()
        let t = lastVoiceTime
        samplesLock.unlock()
        guard t > 0 else { return .infinity }
        return CFAbsoluteTimeGetCurrent() - t
    }
    /// FFT is rebuilt only when the analysis rate changes, not per hold.
    private var fftRate: Double = 0

    init() {
        // Engine path only: a device change — AirPods connecting, headphones
        // un/plugged, a sample-rate switch — makes AVAudioEngine reconfigure:
        // the engine STOPS and the input node's format may be different
        // afterwards. Rewire the capture path with the freshly-read format;
        // the WAV survives the switch because it's written in the canonical
        // format, not the device's.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func handleConfigurationChange() {
        guard isRecording, usingEngine else { return }   // next start() reads fresh state anyway
        NSLog("Slive: audio device configuration changed mid-recording — rewiring capture")
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("Slive: input invalid after device change — recording will end at release")
            return
        }
        converter = AVAudioConverter(from: format, to: fileFormat ?? targetFormat)
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
    /// the node really produces; `handle(buffer:)` canonicalizes from the
    /// buffer's own format, so nothing downstream depends on the tap format.
    /// Any raise that still slips through is caught by the Objective-C shim.
    private func installCaptureTap(on input: AVAudioInputNode) -> String? {
        input.removeTap(onBus: 0)   // harmless when none is installed
        return SliveCatchObjCException {
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                self?.handle(buffer: buffer)
            }
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

    /// Begin recording. Returns false if the microphone couldn't be opened.
    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }
        samplesLock.lock()
        lastVoiceTime = 0   // fresh session — no stale voice recency
        sessionSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()
        loggedWriteError = false
        levelCallbackCount = 0
        windowMaxRMS = 0

        usingEngine = Self.usesEngine(echoCancellation: Settings.shared.echoCancellation)
        let fileFormat: AVAudioFormat
        if usingEngine {
            guard let nodeFormat = prepareEngine() else { return false }
            fileFormat = converter != nil ? targetFormat : nodeFormat
        } else {
            converter = nil            // direct capture is canonical already
            fileFormat = targetFormat
        }
        self.fileFormat = fileFormat
        if fft == nil || fftRate != fileFormat.sampleRate {
            fft = FFTProcessor(fftSize: 1024, bandCount: bandCount, sampleRate: fileFormat.sampleRate)
            fftRate = fileFormat.sampleRate
        }

        // The WAV opens BEFORE audio flows so the first buffers land in it.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowy-\(UUID().uuidString).wav")
        do {
            file = try AVAudioFile(forWriting: tmp, settings: fileFormat.settings)
            tempURL = tmp
        } catch {
            NSLog("Slive: could not open temp file: \(error)")
            return false
        }

        let started = usingEngine ? runEngine() : runDirect()
        guard started else {
            // The WAV was opened before capture; a refused mic leaves only its
            // header behind — delete it rather than litter the temp folder.
            file = nil
            try? FileManager.default.removeItem(at: tmp)
            tempURL = nil
            return false
        }
        isRecording = true
        startTime = Date()
        return true
    }

    // MARK: Direct backend

    private func runDirect() -> Bool {
        let uid = Settings.shared.inputDeviceUID
        guard let device = InputDevices.resolve(uid: uid) ?? InputDevices.defaultInputID() else {
            NSLog("Slive: no input device available")
            return false
        }
        do {
            try capture.start(device: device) { [weak self] buffer in
                self?.handle(buffer: buffer)
            }
            return true
        } catch {
            NSLog("Slive: microphone open failed on device \(device): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Engine backend (echo cancellation)

    /// Configure the engine's input for this recording and return the node
    /// format the tap will produce (nil = mic not usable).
    private func prepareEngine() -> AVAudioFormat? {
        let input = engine.inputNode
        // Attach AEC BEFORE reading the format — voice processing changes the
        // node's output format, and the tap + WAV must match what it produces.
        applyVoiceProcessing(input)
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
        return format
    }

    private func runEngine() -> Bool {
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
        return true
    }

    /// Stop recording. Returns the finalized WAV URL (nil on failure) plus the
    /// session's canonical in-memory samples (empty on the native-format
    /// fallback path — transcribe from the file then).
    @discardableResult
    func stop() -> (url: URL?, samples: [Float]) {
        guard isRecording else { return (nil, []) }
        isRecording = false
        if usingEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } else {
            capture.stop()
        }
        let url = tempURL
        file = nil          // closes the file, flushing the WAV header
        tempURL = nil
        fileFormat = nil
        startTime = nil
        // Nudge the meters back to rest.
        DispatchQueue.main.async { [weak self] in
            self?.onLevels?([Float](repeating: 0, count: self?.bandCount ?? 28), 0)
        }
        if usingEngine {
            // Pre-arm for the NEXT hold: prepare() re-allocates the render
            // resources now, off the hot path. (The direct backend keeps its
            // unit initialized between holds by itself.)
            engine.prepare()
        }
        samplesLock.lock()
        let samples = sessionSamples
        sessionSamples = []
        samplesLock.unlock()
        return (url, samples)
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        let out: AVAudioPCMBuffer
        if buffer.format.sampleRate == targetFormat.sampleRate, buffer.format.channelCount == 1 {
            out = buffer   // already canonical (direct backend)
        } else if let conv = currentConverter(for: buffer.format) {
            // Canonicalize (downmix + resample) before anything touches the data.
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
            out = buffer   // native-format fallback
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

        if out.format.sampleRate == targetFormat.sampleRate, out.format.channelCount == 1 {
            // Canonical 16k mono — safe to hand to Whisper.
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
        // Voice recency at full callback rate: the coalesced level dispatch
        // below is fine for visuals but adds staleness — the release tail
        // reads THIS instead, so it can end the moment real silence is observed.
        if instantRMS > 0.03 {
            samplesLock.lock()
            lastVoiceTime = CFAbsoluteTimeGetCurrent()
            samplesLock.unlock()
        }

        // FFT + main-thread dispatch only every 3rd callback: the 60fps easer
        // interpolates the visual identically, and the main thread takes a
        // third of the wakeups.
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

    /// The engine path's converter, rebuilt the moment the buffer format
    /// stops matching: the configuration-change notification can lag the
    /// actual device switch by a few buffers — the buffer's own format is
    /// the only ground truth.
    private func currentConverter(for format: AVAudioFormat) -> AVAudioConverter? {
        if let conv = converter, !conv.inputFormat.isEqual(format) {
            converter = AVAudioConverter(from: format, to: conv.outputFormat)
        }
        return converter
    }
}
