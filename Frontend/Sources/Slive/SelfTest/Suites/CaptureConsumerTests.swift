import AVFoundation
import Foundation

/// AudioRecorder's source selection and consumer fan-out, driven by a fake
/// source with synthetic buffers (no microphone).
@MainActor
enum CaptureConsumerTests {
    static let suite = TestSuite(name: "Capture consumers") { t in
        print("[Capture consumers]")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slive-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func wavCount() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".wav") }.count
        }

        // Source choice: echo cancellation is the only reason for the engine.
        do {
            let direct = FakeSource(), engine = FakeSource()
            let recorder = AudioRecorder(direct: direct, voiceProcessing: engine,
                                         wav: WAVWriter(directory: dir))
            recorder.start(CaptureOptions(deviceUID: "", echoCancellation: false))
            t.check(direct.started == 1 && engine.started == 0, "echo off records on the AUHAL source")
            if let url = recorder.stop().url { try? FileManager.default.removeItem(at: url) }
            recorder.start(CaptureOptions(deviceUID: "", echoCancellation: true))
            t.check(engine.started == 1 && direct.started == 1, "echo on records on the voice-processing source")
            if let url = recorder.stop().url { try? FileManager.default.removeItem(at: url) }
            t.check(engine.stopped == 1 && engine.rearmed == 1, "stop stops then re-arms the source it started")
        }

        // Voice: WAV length, accumulated samples, levels, voice recency.
        do {
            let source = FakeSource()
            let recorder = AudioRecorder(direct: source, voiceProcessing: FakeSource(),
                                         wav: WAVWriter(directory: dir))
            var levels: [([Float], Float)] = []
            recorder.onLevels = { levels.append(($0, $1)) }
            t.check(recorder.start(CaptureOptions()) && recorder.isRecording, "fake source starts")
            t.check(recorder.quietFor() == .infinity, "no voice yet → quiet forever")
            let tone = (0..<1_600).map { Float(sin(Double($0) * 0.3)) * 0.1 }
            for _ in 0..<3 { source.emit(tone) }
            t.check(recorder.quietFor() < 1, "a voiced buffer updates voice recency")
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.check(levels.count == 1 && levels[0].0.count == recorder.bandCount
                    && abs(levels[0].1 - 0.0707) < 0.005,
                    "levels dispatch every 3rd buffer with the window's max RMS",
                    "\(levels.map { $0.1 })")
            let capture = recorder.stop()
            t.equal(capture.samples.count, 4_800, "canonical samples accumulate in memory")
            let frames = capture.url.flatMap { try? AVAudioFile(forReading: $0).length } ?? -1
            t.equal(frames, 4_800, "WAV holds every frame")
            t.check(!AudioRecorder.isDigitalSilence(capture.samples), "a live tone isn't digital silence")
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            t.check(levels.last.map { $0.1 == 0 && $0.0.allSatisfy { $0 == 0 } } ?? false,
                    "stop nudges the meters to rest")
            if let url = capture.url { try? FileManager.default.removeItem(at: url) }
            t.check(!recorder.isRecording && recorder.stop().url == nil, "stop twice is a no-op")
        }

        // A dead mic: zeros all the way.
        do {
            let source = FakeSource()
            let recorder = AudioRecorder(direct: source, voiceProcessing: FakeSource(),
                                         wav: WAVWriter(directory: dir))
            recorder.start(CaptureOptions())
            for _ in 0..<5 { source.emit([Float](repeating: 0, count: 1_600)) }
            t.check(recorder.quietFor() == .infinity, "zeros never count as voice")
            let capture = recorder.stop()
            t.check(AudioRecorder.isDigitalSilence(capture.samples), "all-zero capture is digital silence")
            if let url = capture.url { try? FileManager.default.removeItem(at: url) }
        }

        // Native-format fallback: written to the WAV, never accumulated.
        do {
            let stereo48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let source = FakeSource(format: stereo48)
            let recorder = AudioRecorder(direct: source, voiceProcessing: FakeSource(),
                                         wav: WAVWriter(directory: dir))
            recorder.start(CaptureOptions())
            source.emit([Float](repeating: 0.01, count: 960))
            let capture = recorder.stop()
            let frames = capture.url.flatMap { try? AVAudioFile(forReading: $0).length } ?? -1
            t.check(capture.samples.isEmpty && frames == 960,
                    "non-canonical buffers go to the WAV only (callers transcribe the file)")
            if let url = capture.url { try? FileManager.default.removeItem(at: url) }
        }

        // Failures leave nothing behind.
        do {
            let source = FakeSource()
            source.startSucceeds = false
            let recorder = AudioRecorder(direct: source, voiceProcessing: FakeSource(),
                                         wav: WAVWriter(directory: dir))
            t.check(!recorder.start(CaptureOptions()) && !recorder.isRecording && wavCount() == 0,
                    "a failed start deletes its empty WAV")
            let unusable = FakeSource(format: nil)
            let recorder2 = AudioRecorder(direct: unusable, voiceProcessing: FakeSource(),
                                          wav: WAVWriter(directory: dir))
            t.check(!recorder2.start(CaptureOptions()) && unusable.started == 0 && wavCount() == 0,
                    "an unusable mic never opens a WAV")
        }
    }
}

/// Stands in for the microphone: `emit` plays the audio thread.
private final class FakeSource: AudioSource {
    let format: AVAudioFormat?
    var startSucceeds = true
    private(set) var started = 0, stopped = 0, rearmed = 0
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    init(format: AVAudioFormat? = MicCapture.canonicalFormat) {
        self.format = format
    }

    func prepare(_ options: CaptureOptions) -> AVAudioFormat? { format }

    func start(_ options: CaptureOptions,
               onAudioThreadBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        guard startSucceeds else { return false }
        started += 1
        onBuffer = onAudioThreadBuffer
        return true
    }

    func stop() { stopped += 1; onBuffer = nil }
    func rearm() { rearmed += 1 }

    /// One buffer with `samples` on every channel.
    func emit(_ samples: [Float]) {
        guard let format, let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(format.channelCount) {
            for (i, s) in samples.enumerated() { buffer.floatChannelData![channel][i] = s }
        }
        onBuffer?(buffer)
    }
}
