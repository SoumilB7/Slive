import Foundation

/// Live streaming dictation: words type into the field as you speak
/// (`ContinuousDictation` runs the stream; this mode starts and ends it).
/// With Type at cursor off nothing is typed: the stream still transcribes
/// and its text ends in the copy box, as a dictation's does.
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
        continuous.onMicLost = { [weak self] in self?.micLost() }
    }

    /// The running session's mic dropped (set until its `end` reads it).
    private var lostMic = false

    /// The mic dropped mid-stream: typing just stopped with no word why. End
    /// the session now, as a release would, and say so.
    private func micLost() {
        guard continuous.isActive else { return }
        lostMic = true
        ctx.session.endToggle()   // else the next tap is eaten as this session's "stop"
        end()
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
        // A repeat begin while streaming is a no-op. A previous session's
        // final pass never blocks: it yields the field and pill to this one.
        guard !continuous.isActive, !ctx.recorder.isRecording else { return }
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

        // Read once: flipping Type at cursor mid-stream changes the next
        // session, never this one's half-typed text. Off, the pill is the
        // dictation waveform — the pen's scribble promises words at the
        // caret, and this session ends like a dictation, in the copy box.
        let typeAtCursor = ctx.settings.autoInsert
        ctx.presenter.listening(typeAtCursor ? .live : .dictation)
        ctx.session.liveStarted()   // for the post-release WPM measurement
        let cue = ctx.cue
        DispatchQueue.main.async { cue(.stream) }

        if !continuous.start(model: streamModel, typeAtCursor: typeAtCursor) { liveStreamFailed() }
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
    /// dictation — so the words are never silently lost. Type at cursor off:
    /// always the copy box, without a note (the user chose it).
    func end() {
        guard continuous.isActive else { return }
        // Timestamp the release now (before the final pass) so the measured pace
        // reflects speaking time, not the final-pass latency.
        let heldSeconds = ctx.session.liveEnded()
        ctx.presenter.transcribing()
        let ctx = self.ctx, continuous = self.continuous
        let lostNote = lostMic ? ModeContext.micLostNote : nil
        lostMic = false
        Task { @MainActor in
            let outcome = await continuous.stop()
            ctx.work.endDictationActivityIfIdle()
            // (Superseded: the release time is the newer session's.)
            if !outcome.superseded, let releasedAt = ctx.session.releasedAt {
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
            // A newer session started meanwhile: the overlay is its pill.
            if outcome.superseded { return }
            if !outcome.typed && !text.isEmpty {
                // Copy button clickable.
                ctx.presenter.result(text, note: lostNote ?? (outcome.typingOff ? nil : ctx.typingBlockedNote()),
                                     collapseAfter: OverlayPresenter.resultDisplayDuration)
            } else if let lostNote {
                ctx.presenter.notice(text.isEmpty ? "Mic disconnected." : lostNote)
            } else {
                ctx.presenter.hideSoon()
            }
        }
    }
}
