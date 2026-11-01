import Foundation
import WhisperKit

/// Continuous dictation on Whisper: WhisperKit's `AudioStreamTranscriber`
/// over the resident pipeline, with the chosen mic routed in
/// (`DeviceRoutedAudioProcessor`).
@MainActor
final class WhisperLiveSession: LiveSession {
    private let recognizer: WhisperRecognizer
    private let tokenizer: WhisperTokenizer
    private let context: LiveContext
    private var transcriber: AudioStreamTranscriber?

    init(recognizer: WhisperRecognizer, tokenizer: WhisperTokenizer, context: LiveContext) {
        self.recognizer = recognizer
        self.tokenizer = tokenizer
        self.context = context
    }

    func snapshot() -> [Float] { recognizer.streamedSamples() }

    func start() -> Bool {
        let pipe = recognizer.kit
        let context = self.context
        // Fresh buffer per session — otherwise the shared audioProcessor would
        // still hold the previous utterance and re-transcribe it from the top.
        pipe.audioProcessor.purgeAudioSamples(keepingLast: 0)

        // Dedupe + instrumentation. The state callback also fires on every mic-
        // energy tick (~10×/s) with an UNCHANGED transcript; only push through real
        // text changes. The logs (filter "Slive.live") show, per hold: each text
        // growth with the gap since the last one + mic energy, an idle heartbeat
        // when text is frozen but audio is flowing (→ VAD skip / loop death), and
        // whether the stream loop ends before release (→ the loop died).
        var lastTranscript = ""
        var lastChange = Date()
        var lastBeat = Date()
        Log.live("START model=\(context.model)")

        // The chosen microphone rides in through a routing wrapper — the
        // transcriber opens the mic itself and would otherwise always take
        // the system default. Resolved at session start (main) so the stream
        // task never touches Settings.
        let routed = DeviceRoutedAudioProcessor(base: pipe.audioProcessor, mic: context.mic)

        let transcriber = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: routed,
            decodingOptions: WhisperRecognizer.decodeOptions(),
            // Confirm text after just one trailing segment (default is 2) so the
            // stable prefix grows sooner.
            requiredSegmentsForConfirmation: 1,
            // Push-to-talk: the user is deliberately speaking the whole time, so
            // don't let the voice-activity gate SKIP transcribe passes on quieter
            // stretches — that's what made live text "hang" mid-phrase and only
            // catch up on release. A low threshold still ignores dead silence but
            // no longer drops real (soft) speech.
            silenceThreshold: 0.1,
            useVAD: true,
            stateChangeCallback: { _, state in
                // Full transcript so far = confirmed prefix + still-forming tail.
                // (NOT state.currentText, which is the volatile decode and can be
                // an early hallucination or the "Waiting for speech..." placeholder.)
                let confirmed = state.confirmedSegments.map { $0.text }.joined()
                let tail = state.unconfirmedSegments.map { $0.text }.joined()
                let transcript = StreamHygiene.clean(confirmed + tail)
                let energy = state.bufferEnergy.last ?? 0
                let now = Date()
                guard transcript != lastTranscript else {   // energy-only tick
                    if now.timeIntervalSince(lastBeat) > 1.0 {
                        Log.live(String(format: "  …frozen %.1fs  energy=%.2f  conf=%d tail=%d",
                                        now.timeIntervalSince(lastChange), energy, confirmed.count, tail.count))
                        lastBeat = now
                    }
                    return
                }
                Log.live(String(format: "+text len=%d (+%d)  gap=%.2fs  energy=%.2f  conf=%d tail=%d  «%@»",
                                transcript.count, transcript.count - lastTranscript.count,
                                now.timeIntervalSince(lastChange), energy, confirmed.count, tail.count,
                                String(transcript.suffix(24))))
                lastChange = now
                lastBeat = now
                lastTranscript = transcript
                let confirmedEnd = Double(state.lastConfirmedSegmentEndSeconds)
                Task { @MainActor in
                    // Confirmed-progress snapshot for the stitched release decode:
                    // on a long hold, release re-decodes only [confirmedEnd-0.3s…]
                    // and stitches onto this text instead of the whole utterance.
                    context.onConfirmed(confirmed, confirmedEnd)
                    context.onUpdate(transcript, 0)
                }
            }
        )
        self.transcriber = transcriber
        recognizer.stream = self
        Task {
            do {
                try await transcriber.startStreamTranscription()
                // Returns when the realtime loop ends. If this logs BEFORE the user
                // releases, the loop died on a decode error (streaming is dead until
                // release). Normally it logs right after stopLiveDictation().
                Log.live("stream loop ended")
            } catch where error is CancellationError || Task.isCancelled {
                Log.live("stream stopped")   // stopLiveDictation, not a failure
            } catch {
                // The mic failed to open: without this the pill kept
                // "listening" and nothing ever typed.
                Log.live("stream ERROR — \(error)")
                let ns = error as NSError
                Log.event("live stream failed to start (\(ns.domain) \(ns.code))")
                FailureReporter.shared.report("live typing", "Live typing couldn't start the microphone.", error: error)
                context.onFailure?()
            }
        }
        return true
    }

    func stop() {
        guard let t = transcriber else { return }
        transcriber = nil
        if recognizer.stream === self { recognizer.stream = nil }
        let recognizer = self.recognizer
        Task {
            // Await the stop FIRST: the stream actor's last in-flight decode
            // reads audioSamples, and purging concurrently would be a
            // cross-domain data race. Once it's confirmed stopped, free the
            // session's audio (64KB/s of Float32 — a long hold leaves tens of
            // MB) instead of holding it until the next session starts.
            await t.stopStreamTranscription()
            // Rapid re-hold guard: if a NEW live session has already started
            // (release → immediate re-press, the common gesture), it owns this
            // same audioProcessor and is filling the buffer right now — purging
            // here would wipe its session mid-stream. Only purge while nobody
            // owns the stream. (This Task runs on the main actor, so the check
            // can't race the setter in `start`.)
            guard recognizer.stream == nil else { return }
            recognizer.kit.audioProcessor.purgeAudioSamples(keepingLast: 0)
        }
    }
}
