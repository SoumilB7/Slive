import Foundation

/// Live streaming dictation: words type into the field as you speak
/// (`ContinuousDictation` runs the stream; this mode starts and ends it).
@MainActor final class StreamMode: DictationMode {
    static let action = HotkeyAction.stream

    private let ctx: ModeContext
    private let continuous: ContinuousDictation

    init(_ ctx: ModeContext, continuous: ContinuousDictation) {
        self.ctx = ctx
        self.continuous = continuous
        let model = ctx.presenter.model
        continuous.onEnergy = { [weak model] energy in model?.pushStreamEnergy(energy) }
        continuous.onFailure = { [weak self] in self?.liveStreamFailed() }
    }

    var isCapturing: Bool { continuous.isActive }

    func cancel() {
        if continuous.isActive { continuous.cancel() }
    }

    /// ✕ or quit: stop the stream; a final pass in flight types nothing.
    func dismiss() {
        continuous.cancel()
    }

    /// Start live dictation: stream transcription from the mic and type each
    /// confirmed word straight into the focused field as you speak, showing the
    /// still-forming tail in the overlay. Needs a model already loaded.
    func begin() {
        guard !ctx.recorder.isRecording else { return }
        guard ctx.micAllowed() else { return }
        ctx.work.cancelRequest()
        ctx.presenter.cancelCollapse()

        // Streaming can't wait on a first-time model load — it needs one in
        // memory now. A fresh install's continuous model (Parakeet) isn't even
        // downloaded, and nothing downloaded it: every press said "Loading
        // model" forever. So fetch it, and stream meanwhile on whatever IS
        // loaded — the previous continuous model, else the dictation model.
        let whisper = ctx.speech
        let wanted = ctx.settings.continuousModel
        let fetching = ctx.models.downloadContinuousModelIfNeeded(retryFailed: true)
        let fallback = [ctx.models.servingContinuousModel, ctx.models.servingDictationModel]
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
            ctx.presenter.notice(msg, collapseAfter: 3.5)
            return
        }

        ctx.presenter.listening(.live)   // same small waveform pill as normal dictation
        ctx.session.liveStarted()   // for the post-release WPM measurement
        let cue = ctx.cue
        DispatchQueue.main.async { cue(.stream) }

        if !continuous.start(model: streamModel) { liveStreamFailed() }
    }

    /// The live stream couldn't start (its mic wouldn't open — now, or
    /// moments later for Whisper's async start). The pill used to keep
    /// "listening" while nothing ever typed.
    private func liveStreamFailed() {
        ctx.session.liveFailed()
        ctx.presenter.notice(ModeContext.micFailedMessage)
    }

    /// Stop live dictation: run the final accurate pass (which also catches the
    /// trailing audio), record the full text, and close the overlay. The pill
    /// shows the loading dots briefly while that final pass runs. If nothing
    /// could be typed live (no editable field was focused), the transcript is
    /// surfaced in the copy/dismiss result box instead — same as normal
    /// dictation — so the words are never silently lost.
    func end() {
        guard continuous.isActive else { return }
        // Timestamp the release now (before the final pass) so the measured pace
        // reflects speaking time, not the final-pass latency.
        let heldSeconds = ctx.session.liveEnded()
        ctx.presenter.transcribing()
        let ctx = self.ctx, continuous = self.continuous
        Task { @MainActor in
            let outcome = await continuous.stop()
            ctx.work.endDictationActivityIfIdle()
            if let releasedAt = ctx.session.releasedAt {
                Log.event(String(format: "stream release→final %.2fs (tail+final pass)",
                      Date().timeIntervalSince(releasedAt)))
                ctx.session.releasedAt = nil
            }
            // ✕ during the final pass: the overlay is gone (or a newer
            // session owns it) — touch nothing.
            if outcome.cancelled { return }
            let text = outcome.text
            if !text.isEmpty {
                ctx.records.addToHistory(text)
                ctx.records.recordPace(text, seconds: heldSeconds)  // after write
            }
            if !outcome.typed && !text.isEmpty {
                // Copy button clickable.
                ctx.presenter.result(text, note: ctx.typingBlockedNote(),
                                     collapseAfter: OverlayPresenter.resultDisplayDuration)
            } else {
                ctx.presenter.hideSoon()
            }
        }
    }
}
