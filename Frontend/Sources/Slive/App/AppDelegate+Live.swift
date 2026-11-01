import AppKit

/// Live streaming dictation: words type into the field as you speak.
extension AppDelegate {
    // MARK: - Live streaming dictation

    /// Start live dictation: stream transcription from the mic and type each
    /// confirmed word straight into the focused field as you speak, showing the
    /// still-forming tail in the overlay. Needs a model already loaded.
    func beginLiveDictation() {
        guard !recorder.isRecording else { return }
        guard micAllowed() else { return }
        transcribeTask?.cancel(); transcribeTask = nil
        presenter.cancelCollapse()

        // Streaming can't wait on a first-time model load — it needs one in
        // memory now. A fresh install's continuous model (Parakeet) isn't even
        // downloaded, and nothing downloaded it: every press said "Loading
        // model" forever. So fetch it, and stream meanwhile on whatever IS
        // loaded — the previous continuous model, else the dictation model.
        let wanted = Settings.shared.continuousModel
        let fetching = residency.downloadContinuousModelIfNeeded(retryFailed: true)
        let fallback = [residency.servingContinuousModel, residency.servingDictationModel]
            .compactMap { $0 }.first { whisper.isReady($0) }
        let streamModel = whisper.servingModel(wanted: wanted, fallback: fallback)
        guard whisper.isReady(streamModel) else {
            whisper.select(wanted)
            // The real state: a failed model said "Loading" forever.
            let msg: String
            switch whisper.status(for: wanted) {
            case .downloading(let p):
                msg = "Downloading model · \(Int(p * 100))%. Try again shortly."
            case _ where fetching:
                msg = "Downloading model. Try again shortly."
            case .failed(let e):
                msg = "Model failed: \(e)"
            default:
                msg = "Loading model. Try again shortly."
            }
            presenter.notice(msg, collapseAfter: 3.5)
            return
        }

        presenter.listening(.live)   // same small waveform pill as normal dictation
        session.liveStarted()   // for the post-release WPM measurement
        DispatchQueue.main.async { FeedbackPlayer.shared.playActivation(for: .stream) }

        if !continuous.start(model: streamModel) { liveStreamFailed() }
    }

    /// The live stream couldn't start (its mic wouldn't open — now, or
    /// moments later for Whisper's async start). The pill used to keep
    /// "listening" while nothing ever typed.
    func liveStreamFailed() {
        session.liveFailed()
        presenter.notice(Self.micFailedMessage)
    }

    /// Stop live dictation: run the final accurate pass (which also catches the
    /// trailing audio), record the full text, and close the overlay. The pill
    /// shows the loading dots briefly while that final pass runs. If nothing
    /// could be typed live (no editable field was focused), the transcript is
    /// surfaced in the copy/dismiss result box instead — same as normal
    /// dictation — so the words are never silently lost.
    func stopLiveDictation() {
        guard continuous.isActive else { return }
        // Timestamp the release now (before the final pass) so the measured pace
        // reflects speaking time, not the final-pass latency.
        let heldSeconds = session.liveEnded()
        presenter.transcribing()
        Task { @MainActor in
            let outcome = await continuous.stop()
            endDictationActivityIfIdle()
            if let releasedAt = session.releasedAt {
                Log.event(String(format: "stream release→final %.2fs (tail+final pass)",
                      Date().timeIntervalSince(releasedAt)))
                session.releasedAt = nil
            }
            // ✕ during the final pass: the overlay is gone (or a newer
            // session owns it) — touch nothing.
            if outcome.cancelled { return }
            let text = outcome.text
            if !text.isEmpty {
                HistoryStore.shared.add(text)
                SpeakingStats.shared.record(text: text, seconds: heldSeconds)  // after write
            }
            if !outcome.typed && !text.isEmpty {
                // Copy button clickable.
                presenter.result(text, note: PasteEngine.typingBlockedNote,
                                 collapseAfter: OverlayPresenter.resultDisplayDuration)
            } else {
                presenter.hideSoon()
            }
        }
    }
}
