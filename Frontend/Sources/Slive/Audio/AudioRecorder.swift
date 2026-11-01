import AVFoundation
import Foundation

/// Captures microphone audio into a temporary WAV file while emitting
/// real-time spectral levels for the visualiser. One instance per app;
/// call `start()` on key-down and `stop()` on key-up.
///
/// An `AudioSource`, chosen per recording, feeds every `BufferConsumer`:
/// - **`AUHALSource`** (echo cancellation off — the default): the chosen mic
///   and nothing else, so a Bluetooth headset playing music stays in A2DP.
/// - **`VoiceProcessingSource`** (echo cancellation on): AVAudioEngine with
///   the system voice-processing chain, on the default route.
///
/// Threading: main thread only, except `fanOut` (AUDIO THREAD) and
/// `quietFor()` (any thread). Not `@MainActor`: the audio-thread closure it
/// hands its source would inherit the isolation.
final class AudioRecorder {
    /// Called on the main thread ~15×/sec with (bands 0...1, rms 0...1).
    var onLevels: (([Float], Float) -> Void)? {
        get { meter.onLevels }
        set { meter.onLevels = newValue }
    }

    private(set) var isRecording = false
    private(set) var startTime: Date?
    var bandCount: Int { meter.bandCount }

    private let direct: AudioSource
    private let voiceProcessing: AudioSource
    /// Which source the CURRENT recording runs on.
    private var source: AudioSource?

    private let wav: WAVWriter
    private let meter = LevelMeter(bandCount: 14)
    private let accumulator = SampleAccumulator()
    private let voice = VoiceActivity()
    /// Every buffer goes to each, in this order.
    private let consumers: [BufferConsumer]
    private let canonicalRate = MicCapture.canonicalFormat.sampleRate

    init(direct: AudioSource = AUHALSource(),
         voiceProcessing: AudioSource = VoiceProcessingSource(),
         wav: WAVWriter = WAVWriter()) {
        self.direct = direct
        self.voiceProcessing = voiceProcessing
        self.wav = wav
        consumers = [wav, accumulator, voice, meter]
    }

    /// Echo cancellation is the only reason to run the engine.
    static func usesEngine(echoCancellation: Bool) -> Bool { echoCancellation }

    static func isDigitalSilence(_ samples: [Float]) -> Bool {
        SampleAccumulator.isDigitalSilence(samples)
    }

    /// Seconds since the mic last heard voice-level audio (see `VoiceActivity`).
    func quietFor() -> TimeInterval { voice.quietFor() }

    /// Begin recording with the options in Settings.
    @discardableResult
    func start() -> Bool { start(.fromSettings()) }

    /// Begin recording. Returns false if the microphone couldn't be opened.
    @discardableResult
    func start(_ options: CaptureOptions) -> Bool {
        guard !isRecording else { return true }
        let source = Self.usesEngine(echoCancellation: options.echoCancellation) ? voiceProcessing : direct
        guard let format = source.prepare(options) else { return false }
        do {
            for consumer in consumers { try consumer.begin(format: format) }
        } catch {
            wav.discard()
            return false
        }
        let started = source.start(options) { [weak self] buffer in self?.fanOut(buffer) }
        guard started else {
            // Nobody will ever stop() this hold, so nobody would ever clean up
            // its (empty) WAV — close it and delete it here, or every failed
            // hold leaks a slive-*.wav into the temp directory.
            wav.discard()
            return false
        }
        self.source = source
        isRecording = true
        startTime = Date()
        return true
    }

    /// Stop recording. Returns the finalized WAV URL (nil on failure) plus the
    /// session's canonical in-memory samples (empty on the native-format
    /// fallback path — transcribe from the file then).
    @discardableResult
    func stop() -> (url: URL?, samples: [Float]) {
        guard isRecording, let source else { return (nil, []) }
        isRecording = false
        source.stop()
        for consumer in consumers { consumer.end() }   // WAV closes; meters go to rest
        let url = wav.takeURL()
        startTime = nil
        source.rearm()
        return (url, accumulator.take())
    }

    /// AUDIO THREAD: one source buffer to every consumer.
    private func fanOut(_ pcm: AVAudioPCMBuffer) {
        let buffer = CapturedBuffer(pcm, canonicalRate: canonicalRate)
        for consumer in consumers { consumer.consume(buffer) }
    }
}
