import CoreAudio
import FluidAudio
import Foundation

/// Continuous (live) dictation on Parakeet.
///
/// Whisper's continuous mode runs on WhisperKit's AudioStreamTranscriber.
/// Parakeet needs no streaming machinery: it decodes in ~50–100ms, so the
/// session captures (MicCapture, the chosen mic) and, whenever ≥0.25s of new
/// audio has arrived, re-transcribes a WINDOW — the audio since the last
/// settled word — and hands committed + window text to LiveTypist. Words
/// that two passes agree on and that end well before the window's edge are
/// settled: committed once, never decoded again, and the window moves past
/// them. (It used to re-transcribe the whole hold every pass — work grew with
/// the square of the hold's length and kept the Neural Engine busy nonstop.)
/// Each window also re-decodes `leftContext` seconds before the cut so the
/// decoder hears the sentence it continues; only words after the cut count
/// (cutting cold lost the word at the seam: "side of it. Please" → "side of
/// please"). Release still decodes the whole hold once (ContinuousDictation)
/// — ~0.2s for 35s on Parakeet, and the most accurate text.
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
    /// A word settles when two passes agree on it and it ends at least this
    /// long before the window's edge (the decoder still revises the edge).
    static let settleMargin: Double = 1.5
    /// Settle only once the window is this long, so every pass keeps context.
    static let minWindowSeconds: Double = 4
    /// Past this, settle without agreement — a window must never grow forever.
    static let maxWindowSeconds: Double = 20
    /// Audio before the cut re-decoded as context (its words are dropped).
    static let leftContext: Double = 2
    /// Pause between polls when there isn't enough new audio yet.
    static let pollNanoseconds: UInt64 = 60_000_000

    private let engine: ParakeetEngine
    private let onUpdate: @MainActor (String) -> Void
    let buffer = SampleBuffer()
    private var loop: Task<Void, Never>?
    private var usesMic = false
    private(set) var passes = 0
    /// Settled text, and where its audio ends (seconds from the hold's start).
    private(set) var confirmedText = ""
    private var cut: Double = 0

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

    /// How many leading words of `current` settle: the same word (ignoring
    /// case and punctuation) in the previous pass, ending before `before`.
    static func settledCount(previous: [WordTiming], current: [WordTiming], before: Double) -> Int {
        func key(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        var n = 0
        while n < previous.count, n < current.count, current[n].endTime <= before,
              key(previous[n].word) == key(current[n].word) { n += 1 }
        return n
    }

    /// `settled` + `more`. A window that starts mid-sentence comes back
    /// capitalised ("…we ran it And then"), so its first word is lowercased
    /// unless the settled text ended a sentence (or the word is "I" / an acronym).
    static func join(_ settled: String, _ more: String) -> String {
        guard !settled.isEmpty else { return more }
        guard !more.isEmpty else { return settled }
        var tail = more
        let endsSentence = settled.last.map { ".?!".contains($0) } ?? true
        let chars = Array(tail.prefix(2))
        if !endsSentence, chars.count == 2, chars[0].isUppercase, chars[1].isLowercase {
            tail = tail.prefix(1).lowercased() + tail.dropFirst()
        }
        return settled + " " + tail
    }

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
            var previous: [WordTiming] = []   // last pass's unsettled words (hold time)
            var last = ""
            while !Task.isCancelled {
                guard let self else { return }
                audio.append(contentsOf: self.buffer.copy(from: audio.count))
                guard audio.count - decoded >= Self.minNewSamples else {
                    try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
                    continue
                }
                decoded = audio.count
                let end = Double(audio.count) / 16_000
                let cutSample = min(audio.count, Int(self.cut * 16_000))
                let newSeconds = end - self.cut
                guard TranscriptionModel.trimSilence(Array(audio[cutSample...])).count > 16_000 / 3 else {
                    // Silence after settled words: keep the window short.
                    if newSeconds > 2 { self.cut = end - 0.5; previous = [] }
                    continue
                }
                let start = max(0, cutSample - Int(Self.leftContext * 16_000))
                guard let found = try? await self.engine.transcribeWords(Array(audio[start...])) else { continue }
                if Task.isCancelled { return }
                self.passes += 1
                let offset = Double(start) / 16_000
                // Only words after the cut; the context's words are settled already.
                let words = found.map {
                    WordTiming(word: $0.word, startTime: $0.startTime + offset, endTime: $0.endTime + offset)
                }.filter { ($0.startTime + $0.endTime) / 2 >= self.cut }
                let edge = end - Self.settleMargin
                var settled = 0
                if newSeconds >= Self.minWindowSeconds {
                    settled = newSeconds >= Self.maxWindowSeconds
                        ? words.prefix { $0.endTime <= edge }.count
                        : Self.settledCount(previous: previous, current: words, before: edge)
                }
                if settled > 0 {
                    self.confirmedText = Self.join(self.confirmedText,
                                                   words[0..<settled].map(\.word).joined(separator: " "))
                    // Cut midway between the last settled word and the next one.
                    let next = settled < words.count ? words[settled].startTime : end
                    self.cut = max(self.cut, (words[settled - 1].endTime + next) / 2)
                }
                previous = Array(words[settled...])
                let text = Self.join(self.confirmedText, previous.map(\.word).joined(separator: " "))
                if !text.isEmpty, text != last {
                    last = text
                    self.onUpdate(text)
                }
            }
        }
    }
}
