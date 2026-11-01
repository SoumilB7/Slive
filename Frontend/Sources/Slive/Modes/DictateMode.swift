import Foundation

/// Hold-to-talk dictation: record → post-release tail → decode → type, in
/// speaking order. Every release queues; its text goes out through the
/// context's sink (typed, or the copy box when auto-insert is off).
@MainActor final class DictateMode: RecordingRoute {
    static let action = HotkeyAction.dictate
    let listenKind = OverlayState.ListenKind.dictation
    let logLabel = "dictation"
    let droppedByDismiss = false

    private let ctx: ModeContext
    private let capture: HoldCapture

    init(_ ctx: ModeContext) {
        self.ctx = ctx
        capture = HoldCapture(ctx: ctx)
    }

    func begin() { capture.begin(self) }
    func end() { capture.end(self) }
    func cancel() { capture.cancel() }
    /// Released dictations are NOT cancelled: their words were spoken, so
    /// they still type (or surface a copy box) when decoded.
    func dismiss() {}
    var isCapturing: Bool { capture.isCapturing }

    func willRecord() {}
    func prepare() {}

    func deliver(_ release: DecodedRelease, prepared: Void) async {
        deliverDictation(release.text, audioURL: release.audioURL, releasedAt: release.releasedAt,
                         waitedForModel: release.waitedForModel, seconds: release.seconds,
                         ownsOverlay: release.queueID.map { ctx.ownsOverlay($0) } ?? !ctx.session.isSessionLive)
    }

    // MARK: - Delivery

    /// Type one released dictation — every dictation lands here, in speaking
    /// order. There is no overlay-phase guard: by now the overlay may show the
    /// "Preparing" box or a newer hold, and that guard dropped every waited
    /// dictation (Oct 29: decoded "→ 18 chars", never typed). The overlay is
    /// only touched when this dictation owns it; otherwise the text still
    /// types and lands in history. (The latency assertion is ended by the
    /// caller's task once nothing else needs it.)
    func deliverDictation(_ text: String, audioURL: URL, releasedAt: Date?,
                          waitedForModel: Bool, seconds: TimeInterval,
                          ownsOverlay: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if ownsOverlay { ctx.presenter.hideSoon() }
            return
        }

        // TYPE FIRST. The keystrokes are dispatched (or the copy box surfaced)
        // before any bookkeeping below, so nothing — history, the training
        // save, stats — can ever sit in front of the typeout. This ordering is
        // the guarantee; saving happens strictly after the text is on its way.
        // (Auto-insert off: the sink is the copy box, which never types.)
        let typed = ctx.sink.deliver(trimmed) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.ctx.presenter.isIdle else { return }
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
            if typed { ctx.presenter.hideSoon() }
            else {
                // Say why, when it's something the user can fix (not when
                // they turned typing off themselves).
                showDictationCopyBox(trimmed, note: ctx.blockedNote)
            }
        } else if !typed {
            Log.event("dictation not typed (overlay busy) — kept in history")
        }

        // ---- Bookkeeping, strictly after the typeout dispatch ----
        recordDictation(trimmed, audioURL: audioURL, seconds: seconds)
    }

    /// History, training pair and speaking stats for one delivered dictation.
    private func recordDictation(_ trimmed: String, audioURL: URL?, seconds: TimeInterval) {
        ctx.records.addToHistory(trimmed)          // always keep it in the catalogue
        if let audioURL { ctx.records.addTrainingPair(trimmed, audioURL: audioURL) }
        ctx.records.recordPace(trimmed, seconds: seconds)
    }

    private func showDictationCopyBox(_ text: String, note: String? = nil) {
        // Order the panel in first: the late delivery-failure callback lands
        // after hideSoon has already hidden it, and the copy box was
        // built off-screen (words neither typed nor shown).
        ctx.presenter.notice(text, note: note, collapseAfter: OverlayPresenter.resultDisplayDuration)
    }
}
