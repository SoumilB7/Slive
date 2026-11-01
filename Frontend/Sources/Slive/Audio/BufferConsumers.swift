import Accelerate
import AVFoundation
import Foundation

/// One source buffer as every consumer sees it, measured once per callback
/// (no copy, no allocation). Valid only for the duration of `consume`.
struct CapturedBuffer {
    let pcm: AVAudioPCMBuffer
    /// Channel 0; empty when the buffer has no float data or no frames.
    let mono: UnsafeBufferPointer<Float>
    /// 16 kHz mono — safe to hand to Whisper.
    let isCanonical: Bool
    /// RMS of `mono` (0 when empty) — cheap vDSP, shared by the level meter
    /// and voice activity.
    let rms: Float

    init(_ pcm: AVAudioPCMBuffer, canonicalRate: Double) {
        self.pcm = pcm
        isCanonical = pcm.format.sampleRate == canonicalRate && pcm.format.channelCount == 1
        let frames = Int(pcm.frameLength)
        if let channelData = pcm.floatChannelData, frames > 0 {
            mono = UnsafeBufferPointer(start: channelData[0], count: frames)
            var meanSquare: Float = 0
            vDSP_measqv(channelData[0], 1, &meanSquare, vDSP_Length(frames))
            rms = sqrtf(meanSquare)
        } else {
            mono = UnsafeBufferPointer(start: nil, count: 0)
            rms = 0
        }
    }
}

/// Something done with every captured buffer. `begin`/`end` run on the main
/// thread around a recording; `consume` runs ON THE AUDIO THREAD — no
/// allocation or locking beyond what the consumer documents.
///
/// Adding a consumer = one conforming class, appended to
/// `AudioRecorder.consumers`.
protocol BufferConsumer: AnyObject {
    /// Before audio flows, with the format buffers will have. Throwing
    /// aborts the recording's start.
    func begin(format: AVAudioFormat) throws
    func consume(_ buffer: CapturedBuffer)
    /// After the source stopped.
    func end()
}

extension BufferConsumer {
    func begin(format: AVAudioFormat) throws {}
    func end() {}
}

// MARK: - WAV

/// Writes the recording to a temporary WAV (kept alongside the in-memory
/// samples for training capture and the file fallback).
final class WAVWriter: BufferConsumer {
    private let directory: URL
    private var file: AVAudioFile?
    private var url: URL?
    private var loggedWriteError = false

    init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
    }

    /// The WAV opens BEFORE audio flows so the first buffers land in it.
    func begin(format: AVAudioFormat) throws {
        loggedWriteError = false
        let tmp = directory.appendingPathComponent("slive-\(UUID().uuidString).wav")
        do {
            file = try AVAudioFile(forWriting: tmp, settings: format.settings)
            url = tmp
        } catch {
            NSLog("Slive: could not open temp file: \(error)")
            try? FileManager.default.removeItem(at: tmp)   // a half-created file, if any
            throw error
        }
    }

    func consume(_ buffer: CapturedBuffer) {
        guard let file else { return }
        do { try file.write(from: buffer.pcm) } catch {
            // A silent write failure here is how recordings break invisibly
            // — say so once per recording.
            if !loggedWriteError {
                loggedWriteError = true
                NSLog("Slive: WAV write failed: \(error)")
            }
        }
    }

    func end() {
        file = nil          // closes the file, flushing the WAV header
    }

    /// The finished WAV; the caller owns (and removes) it from here on.
    func takeURL() -> URL? {
        defer { url = nil }
        return url
    }

    /// Close and delete — the recording never started, so nobody would ever
    /// clean it up.
    func discard() {
        file = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }
}

// MARK: - Level meter

/// Spectral bands + loudness for the visualiser, on the main thread.
///
/// Level-update coalescing: the meters ease at 60fps anyway, so dispatching
/// every tap callback (~47/s) to the main thread bought nothing. Every 3rd
/// callback we FFT + dispatch, forwarding the running-MAX RMS across the
/// window so the adaptive release tail's voice detection keeps per-callback
/// fidelity (a max can't miss a voiced blip between dispatches).
final class LevelMeter: BufferConsumer {
    /// Called on the main thread ~15×/sec with (bands 0...1, rms 0...1).
    var onLevels: (([Float], Float) -> Void)?
    let bandCount: Int

    private var fft: FFTProcessor?
    /// FFT is rebuilt only when the analysis rate changes, not per hold.
    private var fftRate: Double = 0
    private var callbackCount = 0
    private var windowMaxRMS: Float = 0

    init(bandCount: Int = 14) {
        self.bandCount = bandCount
    }

    func begin(format: AVAudioFormat) throws {
        callbackCount = 0
        windowMaxRMS = 0
        if fft == nil || fftRate != format.sampleRate {
            fft = FFTProcessor(fftSize: 1024, bandCount: bandCount, sampleRate: format.sampleRate)
            fftRate = format.sampleRate
        }
    }

    func consume(_ buffer: CapturedBuffer) {
        guard !buffer.mono.isEmpty else { return }
        windowMaxRMS = max(windowMaxRMS, buffer.rms)

        // FFT + main-thread dispatch only every 3rd callback: the 60fps easer
        // interpolates the visual identically, and the main thread takes a
        // third of the wakeups.
        callbackCount += 1
        guard callbackCount >= 3 else { return }
        callbackCount = 0
        let rms = windowMaxRMS
        windowMaxRMS = 0

        // Mono channel 0 of the canonical buffer feeds the analyser.
        let mono = Array(buffer.mono)
        let bands = fft?.process(mono) ?? []

        DispatchQueue.main.async { [weak self] in
            self?.onLevels?(bands, rms)
        }
    }

    /// Nudge the meters back to rest.
    func end() {
        DispatchQueue.main.async { [weak self] in
            self?.onLevels?([Float](repeating: 0, count: self?.bandCount ?? 28), 0)
        }
    }
}

// MARK: - Samples

/// The session's canonical (16k mono) samples, accumulated in the tap so the
/// release path can transcribe FROM MEMORY — skipping the WAV close/flush →
/// reopen → read → (re)parse round-trip (~5-30ms per dictation). Only filled
/// when the buffers are canonical (native-format fallback → empty → callers
/// use the file). Guarded by a lock: the audio thread appends while `take()`
/// reads.
final class SampleAccumulator: BufferConsumer {
    private var samples: [Float] = []
    private let lock = NSLock()

    func begin(format: AVAudioFormat) throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func consume(_ buffer: CapturedBuffer) {
        guard buffer.isCanonical, !buffer.mono.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: buffer.mono)
        lock.unlock()
    }

    /// Everything accumulated so far; leaves the accumulator empty.
    func take() -> [Float] {
        lock.lock()
        let taken = samples
        samples = []
        lock.unlock()
        return taken
    }

    /// A hold whose every sample is (near) digital zero heard nothing at all:
    /// macOS hands a mic without permission — or a dead input — pure zeros,
    /// and that used to fade away like an ordinary silent hold. Any live mic,
    /// even in a quiet room, has a noise floor far above this. Pure;
    /// self-tested.
    static func isDigitalSilence(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak < 2e-5
    }
}

// MARK: - Voice activity

/// Voice recency at full callback rate: the coalesced level dispatch is fine
/// for visuals but adds staleness — the release tail reads THIS instead, so
/// it can end the moment real silence is observed.
final class VoiceActivity: BufferConsumer {
    /// RMS above which a callback counts as voice.
    static let threshold: Float = 0.03

    /// Last callback whose RMS crossed the threshold (written on the audio
    /// thread, read from main).
    private var lastVoiceTime: CFAbsoluteTime = 0
    private let lock = NSLock()

    func begin(format: AVAudioFormat) throws {
        lock.lock()
        lastVoiceTime = 0   // fresh session — no stale voice recency
        lock.unlock()
    }

    func consume(_ buffer: CapturedBuffer) {
        guard !buffer.mono.isEmpty, buffer.rms > Self.threshold else { return }
        lock.lock()
        lastVoiceTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// Seconds since the mic last heard voice-level audio, at full callback
    /// granularity. `.infinity` before any voice this session — a hold with
    /// no speech releases with no tail at all.
    func quietFor() -> TimeInterval {
        lock.lock()
        let t = lastVoiceTime
        lock.unlock()
        guard t > 0 else { return .infinity }
        return CFAbsoluteTimeGetCurrent() - t
    }
}
