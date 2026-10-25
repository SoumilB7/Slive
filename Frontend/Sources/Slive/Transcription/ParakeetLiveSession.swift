import CoreAudio
import Foundation

/// Continuous (live) dictation on Parakeet.
///
/// Whisper's continuous mode runs on WhisperKit's AudioStreamTranscriber.
/// Parakeet needs no streaming machinery: it decodes a whole utterance in
/// ~50–100ms, so the session simply captures (MicCapture, the chosen mic)
/// and, whenever ≥0.25s of new audio has arrived, re-transcribes EVERYTHING
/// so far — full context every pass, no chunk seams — and hands the text to
/// LiveTypist, which types and corrects it. Passes run back to back (each
/// waits for the last), so the cadence adapts to the decode speed.
/// Release still runs one final full decode of the snapshot
/// (ContinuousDictation.stop), exactly as with Whisper.
@MainActor
final class ParakeetLiveSession {
    /// Audio-thread-safe growing buffer (MicCapture calls in on its IO thread).
    final class SampleBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        func append(_ chunk: UnsafeBufferPointer<Float>) {
            lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        }
        func append(_ chunk: [Float]) {
            lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        }
        /// A fresh copy of every sample from `start` on. Never `samples`
        /// itself: a handed-out array shares its storage, so the audio
        /// thread's next append copied the WHOLE buffer (on the IO thread,
        /// under the lock) whenever a live pass held a snapshot — megabytes
        /// per pass on a long hold.
        func copy(from start: Int = 0) -> [Float] {
            lock.lock(); defer { lock.unlock() }
            guard start < samples.count else { return [] }
            return samples.withUnsafeBufferPointer { Array(UnsafeBufferPointer(rebasing: $0[start...])) }
        }
        func snapshot() -> [Float] { copy() }
    }

    /// New audio needed before another pass (0.25s).
    static let minNewSamples = 4_000
    /// Pause between polls when there isn't enough new audio yet.
    static let pollNanoseconds: UInt64 = 60_000_000

    private let engine: ParakeetEngine
    private let onUpdate: @MainActor (String) -> Void
    let buffer = SampleBuffer()
    private var loop: Task<Void, Never>?
    private var usesMic = false
    private(set) var passes = 0

    init(engine: ParakeetEngine, onUpdate: @escaping @MainActor (String) -> Void) {
        self.engine = engine
        self.onUpdate = onUpdate
    }

    /// Start capturing on `device` and transcribing.
    func start(device: AudioDeviceID) throws {
        let buffer = self.buffer
        try MicCapture.shared.start(device: device) { chunk in
            guard let channel = chunk.floatChannelData else { return }
            buffer.append(UnsafeBufferPointer(start: channel[0], count: Int(chunk.frameLength)))
        }
        usesMic = true
        startLoop()
    }

    /// Start transcribing audio the caller feeds via `buffer.append` — the
    /// headless test path (`Slive --engine-check --live`).
    func startDetached() { startLoop() }

    func snapshot() -> [Float] { buffer.snapshot() }

    /// Stop capture and the loop. A pass already on the Neural Engine
    /// finishes on its own; the caller's final decode queues behind it.
    func stop() {
        loop?.cancel()
        loop = nil
        if usesMic { MicCapture.shared.stop() }
    }

    private func startLoop() {
        loop = Task { [weak self] in
            // The loop's own copy, grown by just the new samples each poll —
            // nothing it holds is shared with the buffer the mic appends to.
            var audio: [Float] = []
            var decoded = 0
            var last = ""
            while !Task.isCancelled {
                guard let self else { return }
                audio.append(contentsOf: self.buffer.copy(from: audio.count))
                guard audio.count - decoded >= Self.minNewSamples else {
                    try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
                    continue
                }
                decoded = audio.count
                let voiced = TranscriptionModel.trimSilence(audio)
                guard voiced.count > 16_000 / 3 else { continue }
                let text = (try? await self.engine.transcribe(Array(voiced))) ?? ""
                if Task.isCancelled { return }
                self.passes += 1
                if !text.isEmpty, text != last {
                    last = text
                    self.onUpdate(text)
                }
            }
        }
    }
}
