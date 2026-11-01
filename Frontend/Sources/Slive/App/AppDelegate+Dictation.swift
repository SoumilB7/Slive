import AppKit

/// Hold-to-talk dictation (and the assistant's capture, which shares it):
/// record → post-release tail → decode → type, in speaking order.
extension AppDelegate {
    // MARK: - Hold-to-talk flow

    func beginRecording() {
        guard !recorder.isRecording else { return }
        guard micAllowed() else { return }
        // A new recording supersedes an in-flight assistant answer and any
        // result box. Released dictations are queued and still type.
        transcribeTask?.cancel()
        transcribeTask = nil
        presenter.cancelCollapse()

        let action = session.currentAction
        presenter.listening(action == .assist ? .assistant : .dictation)
        if action == .assist {
            // Boot the lazy backend NOW, overlapped with the user speaking —
            // by release it's healthy and the answer path skips the
            // multi-second first-use spawn entirely.
            let backend = self.backend
            Task { _ = await backend.ensureHealthy() }
        }
        session.recordingStarted()
        if !recorder.start() {
            Log.event("mic unavailable — hold aborted")
            FailureReporter.shared.report("microphone", "The microphone couldn't start.")
            session.endToggle()   // else the next tap is eaten as this session's "stop"
            presenter.notice(Self.micFailedMessage)
            return
        }
        // Hold the machine at speed for the whole hold→type window (tier
        // knob): no App Nap, no timer coalescing, P-cores clocked — decode
        // latency on battery matches plugged-in.
        if dictationActivity == nil, Settings.shared.resolvedSpeedTier.holdsLatencyAssertion {
            dictationActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Slive dictation")
        }
        // Prime the Neural Engine while the user is still speaking (tier
        // knob; also the Feather tier's reload-on-hold path): after minutes
        // of idle the compiled graph pages back in on first use — pay that
        // now, in parallel with the hold, not after release.
        whisper.primeIfCold(Settings.shared.whisperModel)
        // Subtle audio cue that a call activated — distinct per call type.
        // Posted on the NEXT runloop turn: its engine restart (auto-shutdown
        // wake) is a few ms of main-thread work that shouldn't sit between
        // key-down and the pill/mic being live.
        let cueAction = action
        DispatchQueue.main.async { FeedbackPlayer.shared.playActivation(for: cueAction) }
    }

    /// Drop the latency-critical assertion once a dictation cycle fully ends.
    func stopRecording() {
        guard recorder.isRecording else { return }
        let duration = session.recordedSeconds
        let capture = recorder.stop()
        let wavURL = capture.url
        let samples = capture.samples

        guard let wavURL else {
            presenter.hideSoon()
            endDictationActivityIfIdle()
            return
        }

        // Pure zeros: the mic heard nothing at all (blocked, muted at the
        // hardware, a dead device) — say so instead of fading like silence.
        if samples.count >= 16_000 / 4, AudioRecorder.isDigitalSilence(samples) {
            try? FileManager.default.removeItem(at: wavURL)
            Log.event(String(format: "captured %.1fs of digital silence — no mic signal", duration))
            presenter.notice("No sound. Check your microphone.")
            endDictationActivityIfIdle()
            return
        }

        // Keep the overlay up and show a loading state while we save + transcribe.
        presenter.transcribing()

        // Which shortcut started this recording decides what we do with the text.
        let action = session.currentAction
        let whisperModel = whisper.servingModel(wanted: Settings.shared.whisperModel,
                                                fallback: residency.servingDictationModel)
        let pipeline = DictationPipeline.standard(vocabulary: Settings.shared.hotwords)
        // Queued: every dictation, and an assistant request released while
        // the model isn't ready or behind dictations still in line. A queued
        // release is never cancelled by a newer hold and runs in turn (it
        // times its own release→typed).
        let modelReady = whisper.isReady(whisperModel)
        let queueID: UUID? = DictationQueue.queues(action, modelReady: modelReady,
                                                   queueEmpty: waitingDictations.isEmpty)
            ? waitingDictations.enqueue() : nil
        let releaseTime = session.releasedAt
        if queueID != nil { session.releasedAt = nil }
        // Released while the model is still being prepared (first launch, or
        // macOS purged its compiled-model cache — a minute or two): say so
        // instead of silent "processing" dots. The dictation is kept and
        // types the moment the model is ready, replacing this box. Only
        // promised when a load is running or will start: a model that isn't
        // downloaded or just failed gets its reason from handleNoTranscript.
        if !modelReady, whisper.canBecomeReady(whisperModel) {
            // Clickable, so a stalled load's box can be closed: ✕ hides it,
            // the dictation stays queued and still types once the model is up.
            presenter.result("Loading model. Text will follow.", collapseAfter: nil)
        }

        transcribeTask?.cancel()
        transcribeTask = nil
        // Strong `self` capture: the task always returns (breaking any cycle).
        // An unqueued (assistant) one is cancelled by a new recording so a
        // stale UI update never lands; a queued one runs to the end.
        let task = Task {
            defer { try? FileManager.default.removeItem(at: wavURL) }   // never persisted
            defer {
                if let queueID { self.waitingDictations.finish(queueID) }
                self.endDictationActivityIfIdle()   // every exit, not just the typed one
            }
            Log.event(String(format: "captured %.1fs of audio (%@)", duration, action == .assist ? "assistant" : "dictation"))
            if Task.isCancelled { return }

            // Assistant: capture the screenshot IN PARALLEL with transcription —
            // both happen post-release, and the screencapture subprocess used to
            // sit serially (~200-500ms) in front of the HTTP request.
            let screenshotTask: Task<(mediaType: String, data: String)?, Never>? =
                (action == .assist && Settings.shared.assistantConfig.attachScreenshot)
                ? Task.detached(priority: .userInitiated) { ScreenCapture.fullScreenBase64() }
                : nil

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
                if let queueID, !self.ownsOverlay(queueID) {
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
            if let queueID { await self.waitingDictations.turn(queueID) }
            if Task.isCancelled { return }   // quit, or ✕ on a waiting assistant request

            // 2. Route the transcript: plain dictation types/shows it; the
            //    assistant shortcut needs the (always-on) Python backend to reach
            //    the LLM, so ensure it's up first, then stream the answer.
            switch action {
            case .dictate, .stream:
                // `.stream` never reaches here (it uses the live path), but the
                // file path falls back to plain dictation if it ever did.
                self.deliverDictation(text, audioURL: wavURL, releasedAt: releaseTime,
                                      waitedForModel: waitedForModel, seconds: duration,
                                      ownsOverlay: queueID.map { self.ownsOverlay($0) } ?? !self.session.isSessionLive)
            case .assist:
                if let queueID {
                    // Hand the turn on NOW that the question is in hand — the
                    // LLM stream runs for seconds and held every later
                    // dictation behind it. From here it's an ordinary in-flight
                    // answer: a newer hold or ✕ cancels it via transcribeTask.
                    let owns = self.ownsOverlay(queueID)
                    let mine = self.waitingDictations.handOff(queueID)
                    guard owns else {
                        // A newer hold / dictation has the overlay: it
                        // supersedes this request, as it would an unqueued one.
                        Log.event("queued assistant request superseded by a newer hold — skipped")
                        screenshotTask?.cancel()
                        return
                    }
                    self.transcribeTask?.cancel()
                    self.transcribeTask = mine
                }
                if await self.backend.ensureHealthy() {
                    if Task.isCancelled { return }
                    await self.runAssistant(on: text, screenshot: screenshotTask)
                } else {
                    screenshotTask?.cancel()
                    await MainActor.run { self.showBackendError() }
                }
            }
        }
        if let queueID {
            waitingDictations.track(task, for: queueID, isAssist: action == .assist)
        } else {
            transcribeTask = task
        }
    }

    /// The overlay is this queued dictation's to update: it's the newest one
    /// waiting and no newer hold is live.
    private func ownsOverlay(_ id: UUID) -> Bool {
        waitingDictations.isLast(id) && !session.isSessionLive
    }

    // MARK: - Delivery

    /// Empty/failed transcript. If the model isn't ready, say so (with what to
    /// do); otherwise just fade the overlay (silence / a mis-hit key).
    @MainActor private func handleNoTranscript(afterWaiting: Bool = false) {
        endDictationActivityIfIdle()
        Log.event("no transcript\(afterWaiting ? " after waiting for the model" : "")")
        let serving = whisper.servingModel(wanted: Settings.shared.whisperModel,
                                           fallback: residency.servingDictationModel)
        if afterWaiting, whisper.isReady(serving) || whisper.status(for: serving) == .ready {
            // Never drop a real dictation silently: it had speech, it waited
            // for the model, and still came back empty. (A model that never
            // became ready says why below instead.)
            presenter.result("Missed that. Please repeat.", collapseAfter: 6.0)
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
            presenter.hideSoon(); return
        }
        presenter.result(message, collapseAfter: 5.0)
    }

    /// Type one released dictation — every dictation lands here, in speaking
    /// order. There is no overlay-phase guard: by now the overlay may show the
    /// "Preparing" box or a newer hold, and that guard dropped every waited
    /// dictation (Oct 29: decoded "→ 18 chars", never typed). The overlay is
    /// only touched when this dictation owns it; otherwise the text still
    /// types and lands in history. (The latency assertion is ended by the
    /// caller's task once nothing else needs it.)
    @MainActor private func deliverDictation(_ text: String, audioURL: URL, releasedAt: Date?,
                                             waitedForModel: Bool, seconds: TimeInterval,
                                             ownsOverlay: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if ownsOverlay { presenter.hideSoon() }
            return
        }

        // TYPE FIRST. The keystrokes are dispatched (or the copy box surfaced)
        // before any bookkeeping below, so nothing — history, the training
        // save, stats — can ever sit in front of the typeout. This ordering is
        // the guarantee; saving happens strictly after the text is on its way.
        let typed = Settings.shared.autoInsert && PasteEngine.insertIfPossible(trimmed) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.presenter.isIdle else { return }
                self.showDictationCopyBox(trimmed)
            }
        }
        if let releasedAt {
            // Unconditional: THE number to check when "dictation feels slow".
            if waitedForModel {
                Log.event(String(format: "waited dictation release→%@ %.2fs", typed ? "typed" : "copy box",
                                 Date().timeIntervalSince(releasedAt)))
            } else {
                Log.event(String(format: "release→%@ %.2fs (tail+decode+dispatch)", typed ? "typed" : "copy box",
                                 Date().timeIntervalSince(releasedAt)))
            }
        }
        if ownsOverlay {
            if typed { presenter.hideSoon() }
            else {
                // Say why, when it's something the user can fix (not when
                // they turned typing off themselves).
                showDictationCopyBox(trimmed, note: Settings.shared.autoInsert
                                     ? PasteEngine.typingBlockedNote : nil)
            }
        } else if !typed {
            Log.event("dictation not typed (overlay busy) — kept in history")
        }

        // ---- Bookkeeping, strictly after the typeout dispatch ----
        recordDictation(trimmed, audioURL: audioURL, seconds: seconds)
    }

    /// History, training pair and speaking stats for one delivered dictation.
    @MainActor private func recordDictation(_ trimmed: String, audioURL: URL?, seconds: TimeInterval) {
        HistoryStore.shared.add(trimmed)          // always keep it in the catalogue
        // Training pair (audio + transcript) — only while saving is toggled on
        // and under the size cap. Records regardless of where the text landed.
        if Capabilities.current.training, Settings.shared.captureEdits, !TrainingStore.shared.isOverLimit, let audioURL {
            TrainingStore.shared.addRecording(transcript: trimmed, audioURL: audioURL)
        }
        SpeakingStats.shared.record(text: trimmed, seconds: seconds)
    }

    @MainActor private func showDictationCopyBox(_ text: String, note: String? = nil) {
        // Order the panel in first: the late delivery-failure callback lands
        // after hideSoon has already hidden it, and the copy box was
        // built off-screen (words neither typed nor shown).
        presenter.notice(text, note: note, collapseAfter: OverlayPresenter.resultDisplayDuration)
    }
}
