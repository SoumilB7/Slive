import AppKit

/// What a hold-to-talk mode does with its recording — the parts that differ
/// between dictation and the assistant. The capture, decode and queueing
/// around them are `HoldCapture`'s.
@MainActor protocol RecordingRoute: DictationMode {
    /// Whatever `prepare` starts alongside the decode.
    associatedtype Prepared
    /// The listening pill.
    var listenKind: OverlayState.ListenKind { get }
    /// Names the release in the "captured … of audio (…)" log line.
    var logLabel: String { get }
    /// ✕ drops its queued releases (an answer isn't spoken words).
    var droppedByDismiss: Bool { get }
    /// The mic is about to open — overlap anything slow with the speaking.
    func willRecord()
    /// The release's task is starting, before the decode.
    func prepare() -> Prepared
    /// The decoded, corrected text, in its turn.
    func deliver(_ release: DecodedRelease, prepared: Prepared) async
}

/// One release's decoded text and what's known about it.
struct DecodedRelease {
    let text: String
    let audioURL: URL
    /// When the hotkey lifted (nil when a queued one already logged it).
    let releasedAt: Date?
    let waitedForModel: Bool
    let seconds: TimeInterval
    /// Its place in the DictationQueue (nil = an unqueued assistant request).
    let queueID: UUID?
}

/// Hold-to-talk dictation (and the assistant's capture, which shares it):
/// record → post-release tail → decode → hand to the route, in speaking order.
@MainActor struct HoldCapture {
    let ctx: ModeContext

    var isCapturing: Bool { ctx.recorder.isRecording }

    func begin<R: RecordingRoute>(_ route: R) {
        guard !ctx.recorder.isRecording else { return }
        guard ctx.micAllowed() else { return }
        // A new recording supersedes an in-flight assistant answer and any
        // result box. Released dictations are queued and still type.
        ctx.work.cancelRequest()
        ctx.presenter.cancelCollapse()

        ctx.presenter.listening(route.listenKind)
        route.willRecord()
        ctx.session.recordingStarted()
        if !ctx.recorder.start(ctx.captureOptions()) {
            Log.event("mic unavailable — hold aborted")
            ctx.report("microphone", "The microphone couldn't start.")
            ctx.session.endToggle()   // else the next tap is eaten as this session's "stop"
            ctx.presenter.notice(ModeContext.micFailedMessage)
            return
        }
        // Hold the machine at speed for the whole hold→type window (tier
        // knob): no App Nap, no timer coalescing, P-cores clocked — decode
        // latency on battery matches plugged-in.
        if !ctx.work.holdsDictationActivity, ctx.settings.resolvedSpeedTier.holdsLatencyAssertion {
            ctx.work.beginDictationActivity()
        }
        // Prime the Neural Engine while the user is still speaking (tier
        // knob; also the Feather tier's reload-on-hold path): after minutes
        // of idle the compiled graph pages back in on first use — pay that
        // now, in parallel with the hold, not after release.
        ctx.speech.primeIfCold(ctx.settings.whisperModel)
        // Subtle audio cue that a call activated — distinct per call type.
        // Posted on the NEXT runloop turn: its engine restart (auto-shutdown
        // wake) is a few ms of main-thread work that shouldn't sit between
        // key-down and the pill/mic being live.
        let cueAction = route.action
        let cue = ctx.cue
        DispatchQueue.main.async { cue(cueAction) }
    }

    /// A false start: stop and throw the fragment away.
    func cancel() {
        if ctx.recorder.isRecording {
            let capture = ctx.recorder.stop()
            if let url = capture.url { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Drop the latency-critical assertion once a dictation cycle fully ends.
    func end<R: RecordingRoute>(_ route: R) {
        let ctx = self.ctx
        guard ctx.recorder.isRecording else { return }
        let duration = ctx.session.recordedSeconds
        let capture = ctx.recorder.stop()
        let wavURL = capture.url
        let samples = capture.samples

        guard let wavURL else {
            ctx.presenter.hideSoon()
            ctx.work.endDictationActivityIfIdle()
            return
        }

        // Pure zeros: the mic heard nothing at all (blocked, muted at the
        // hardware, a dead device) — say so instead of fading like silence.
        if samples.count >= 16_000 / 4, AudioRecorder.isDigitalSilence(samples) {
            try? FileManager.default.removeItem(at: wavURL)
            Log.event(String(format: "captured %.1fs of digital silence — no mic signal", duration))
            ctx.presenter.notice("No sound. Check your microphone.")
            ctx.work.endDictationActivityIfIdle()
            return
        }

        // Keep the overlay up and show a loading state while we save + transcribe.
        ctx.presenter.transcribing()

        // Which shortcut started this recording decides what we do with the text.
        let action = route.action
        let whisper = ctx.speech
        let whisperModel = whisper.servingModel(wanted: ctx.settings.whisperModel,
                                                fallback: ctx.models.servingDictationModel)
        let pipeline = DictationPipeline.standard(vocabulary: ctx.settings.hotwords)
        // Queued: every dictation, and an assistant request released while
        // the model isn't ready or behind dictations still in line. A queued
        // release is never cancelled by a newer hold and runs in turn (it
        // times its own release→typed).
        let modelReady = whisper.isReady(whisperModel)
        let queueID: UUID? = DictationQueue.queues(action, modelReady: modelReady,
                                                   queueEmpty: ctx.queue.isEmpty)
            ? ctx.queue.enqueue() : nil
        let releaseTime = ctx.session.releasedAt
        if queueID != nil { ctx.session.releasedAt = nil }
        // Released while the model is still being prepared (first launch, or
        // macOS purged its compiled-model cache — a minute or two): say so
        // instead of silent "processing" dots. The dictation is kept and
        // types the moment the model is ready, replacing this box. Only
        // promised when a load is running or will start: a model that isn't
        // downloaded or just failed gets its reason from handleNoTranscript.
        if !modelReady, whisper.canBecomeReady(whisperModel) {
            // Clickable, so a stalled load's box can be closed: ✕ hides it,
            // the dictation stays queued and still types once the model is up.
            ctx.presenter.result("Loading model. Text will follow.", collapseAfter: nil)
        }

        ctx.work.cancelRequest()
        // Strong captures: the task always returns (breaking any cycle).
        // An unqueued (assistant) one is cancelled by a new recording so a
        // stale UI update never lands; a queued one runs to the end.
        let task = Task {
            defer { try? FileManager.default.removeItem(at: wavURL) }   // never persisted
            defer {
                if let queueID { ctx.queue.finish(queueID) }
                ctx.work.endDictationActivityIfIdle()   // every exit, not just the typed one
            }
            Log.event(String(format: "captured %.1fs of audio (%@)", duration, route.logLabel))
            if Task.isCancelled { return }

            // E.g. the assistant's screenshot, IN PARALLEL with transcription.
            let prepared = route.prepare()

            // 1. Transcribe ON-DEVICE with WhisperKit (Neural Engine) — no backend
            //    needed for STT. Prefer the in-memory canonical samples the
            //    recorder accumulated (skips the WAV reopen/read); fall back to
            //    the file when they're unavailable (native-format fallback, or
            //    the model needs a load — the file path loads it).
            let tTranscribe = Date()
            // Trim leading/trailing silence first: dead air before the first
            // word (hold → think → speak) and the release tail's quiet both
            // cost decode windows and trip fallback thresholds for nothing.
            let voiced = pipeline.prepare(samples)
            var transcript: String?
            var waitedForModel = false
            if voiced.count > 16_000 / 3 {
                // Released while the model is still being prepared (launch,
                // purged compile cache, macOS update): wait for it, then take
                // the NORMAL in-memory path. (Oct 7: the old path decoded the
                // WAV on a just-compiled model, racing the post-load warm-up,
                // came back empty and the dictation was silently dropped.)
                if !whisper.isReady(whisperModel) {
                    waitedForModel = true
                    Log.event("dictation waiting for model \(whisperModel)")
                    _ = await whisper.awaitReady(whisperModel)
                    Log.event(String(format: "model ready after %.1fs of waiting", Date().timeIntervalSince(tTranscribe)))
                }
                transcript = await whisper.transcribeSamples(Array(voiced), model: whisperModel)
                // The first decode on a freshly compiled model gets one retry.
                if waitedForModel, !Task.isCancelled,
                   (transcript ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    Log.event("decode after waiting came back empty — retrying once")
                    transcript = await whisper.transcribeSamples(Array(voiced), model: whisperModel)
                }
            }
            // File fallback: native-format recordings have no canonical
            // samples, and a failed samples decode (model still loading) also
            // lands here. Skipped only when the canonical buffer positively
            // shows the hold was silence.
            if transcript == nil, samples.isEmpty || voiced.count > 16_000 / 3 {
                transcript = await whisper.transcribe(wavURL, model: whisperModel)
            }
            // Engine artifacts out, whichever engine and path decoded it
            // (Whisper's in-memory decode already cleaned: a no-op there).
            transcript = transcript.map(pipeline.clean)
            // Unconditional: one line per dictation, and THE number to check
            // whenever "dictation feels slow" comes up again.
            let decodeSeconds = Date().timeIntervalSince(tTranscribe)
            Log.event(String(format: "decoded %.1fs audio in %.2fs (%@) → %@%@",
                  duration, decodeSeconds, whisperModel,
                  transcript == nil ? "nil" : ((transcript ?? "").isEmpty ? "EMPTY" : "\((transcript ?? "").count) chars"),
                  ProcessInfo.processInfo.isLowPowerModeEnabled
                      ? " [LOW POWER MODE — decode throttled]" : ""))
            // (Speed-graph calibration happens inside transcribeSamples, where
            // the pipe is guaranteed resident — timing here can include a
            // model load, which once poisoned the graph into "~15s".)
            if Task.isCancelled { Log.event("request cancelled after decode (a newer hold, ✕ or quit)"); return }
            guard let decoded = transcript, !decoded.isEmpty else {
                let hadSpeech = voiced.count > 16_000 / 3
                if let queueID, !ctx.ownsOverlay(queueID) {
                    Log.event("queued dictation came back empty (overlay busy, nothing shown)")
                    return
                }
                await MainActor.run { self.handleNoTranscript(afterWaiting: waitedForModel && hadSpeech) }
                return
            }
            // Spell the user's Vocabulary terms the way they typed them
            // (both engines; a no-op when the list is empty).
            let text = pipeline.correct(decoded)
            // Older waiting dictations type first.
            if let queueID { await ctx.queue.turn(queueID) }
            if Task.isCancelled { return }   // quit, or ✕ on a waiting assistant request

            // 2. Route the transcript: plain dictation types/shows it; the
            //    assistant shortcut needs the (always-on) Python backend to reach
            //    the LLM, so ensure it's up first, then stream the answer.
            await route.deliver(DecodedRelease(text: text, audioURL: wavURL, releasedAt: releaseTime,
                                               waitedForModel: waitedForModel, seconds: duration,
                                               queueID: queueID),
                                prepared: prepared)
        }
        if let queueID {
            ctx.queue.track(task, for: queueID, isAssist: route.droppedByDismiss)
        } else {
            ctx.work.request = task
        }
    }

    // MARK: - No transcript

    /// Empty/failed transcript. If the model isn't ready, say so (with what to
    /// do); otherwise just fade the overlay (silence / a mis-hit key).
    private func handleNoTranscript(afterWaiting: Bool = false) {
        ctx.work.endDictationActivityIfIdle()
        Log.event("no transcript\(afterWaiting ? " after waiting for the model" : "")")
        let whisper = ctx.speech
        let serving = whisper.servingModel(wanted: ctx.settings.whisperModel,
                                           fallback: ctx.models.servingDictationModel)
        if afterWaiting, whisper.isReady(serving) || whisper.status(for: serving) == .ready {
            // Never drop a real dictation silently: it had speech, it waited
            // for the model, and still came back empty. (A model that never
            // became ready says why below instead.)
            ctx.presenter.result("Missed that. Please repeat.", collapseAfter: 6.0)
            return
        }
        let message: String?
        switch whisper.status(for: serving) {
        case .notDownloaded:
            message = "Model not downloaded. Open Settings."
        case .downloading(let p):
            message = "Downloading model · \(Int(p * 100))%"
        case .preparing:
            message = "Loading model…"
        case .failed(let e):
            message = "Model failed: \(e)"
        case .ready:
            message = nil   // genuinely empty (silence) — just fade
        }
        guard let message else {
            ctx.presenter.hideSoon(); return
        }
        ctx.presenter.result(message, collapseAfter: 5.0)
    }
}
