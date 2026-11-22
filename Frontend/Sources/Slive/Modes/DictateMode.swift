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
    /// What waits for the overlay to free up, shown together in one box:
    /// unconfirmed dictations' text (oldest first) and the mic-lost note of
    /// one typed while a newer hold owned the overlay.
    private var pendingTexts: [(order: Int, text: String)] = []
    private var deliveryOrder = 0
    private var pendingNote: String?
    private var waitingForIdle = false

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
        deliverDictation(release,
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
    func deliverDictation(_ release: DecodedRelease, ownsOverlay: Bool) {
        let releasedAt = release.releasedAt, waitedForModel = release.waitedForModel
        // A mic that dropped mid-hold left the end unrecorded: say so.
        let lostNote = release.micLost ? ModeContext.micLostNote : nil
        let trimmed = release.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if ownsOverlay { ctx.presenter.hideSoon() }
            return
        }

        // TYPE FIRST. The keystrokes are dispatched (or the copy box surfaced)
        // before any bookkeeping below, so nothing — history, the training
        // save, stats — can ever sit in front of the typeout. This ordering is
        // the guarantee; saving happens strictly after the text is on its way.
        // (Auto-insert off: the sink is the copy box, which never types.)
        deliveryOrder += 1
        let order = deliveryOrder
        let typed = ctx.sink.deliver(trimmed) { [weak self] in
            DispatchQueue.main.async { self?.showWhenIdle(text: trimmed, order: order, note: lostNote) }
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
            if typed, let lostNote { ctx.presenter.notice(lostNote) }
            else if typed { ctx.presenter.hideSoon() }
            else {
                // Say why, when it's something the user can fix (not when
                // they turned typing off themselves).
                showDictationCopyBox(trimmed, note: lostNote ?? ctx.blockedNote)
            }
        } else if !typed {
            Log.event("dictation not typed (overlay busy) — kept in history")
        } else if let lostNote {
            // Typed under a newer hold: still say its end may be missing.
            showWhenIdle(text: nil, note: lostNote)
        }

        // ---- Bookkeeping, strictly after the typeout dispatch ----
        recordDictation(trimmed, release: release)
    }

    /// History, training pair and speaking stats for one delivered dictation.
    /// A stand-in's transcript is no label for the pick's training data, so
    /// only the user's own model makes a training pair.
    private func recordDictation(_ trimmed: String, release: DecodedRelease) {
        ctx.records.addToHistory(trimmed)          // always keep it in the catalogue
        if release.decodedBy == ctx.settings.whisperModel {
            ctx.records.addTrainingPair(trimmed, audioURL: release.audioURL)
        } else {
            Log.event("no training pair — decoded on stand-in \(release.decodedBy)")
        }
        ctx.records.recordPace(trimmed, seconds: release.seconds)
    }

    /// The delivery check ends ~0.9 s after typing, often under a newer
    /// hold or box, so the copy box waits for the overlay to free up rather
    /// than be dropped. Everything waiting shows in ONE box, so a newer one
    /// never replaces an older one and Copy takes all of it.
    private func showWhenIdle(text: String?, order: Int = 0, note: String?) {
        if let text { pendingTexts.append((order, text)) }
        if let note { pendingNote = note }
        guard !waitingForIdle else { return }
        waitingForIdle = true
        ctx.presenter.whenIdle(sessionLive: { [weak self] in self?.ctx.session.isSessionLive ?? false }) { [weak self] in
            guard let self else { return }
            let texts = self.pendingTexts, note = self.pendingNote
            self.pendingTexts = []
            self.pendingNote = nil
            self.waitingForIdle = false
            if !texts.isEmpty {
                self.showDictationCopyBox(texts.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n\n"), note: note)
            } else if let note {
                self.ctx.presenter.notice(note)
            }
        }
    }

    private func showDictationCopyBox(_ text: String, note: String? = nil) {
        // Order the panel in first: the late delivery-failure callback lands
        // after hideSoon has already hidden it, and the copy box was
        // built off-screen (words neither typed nor shown).
        ctx.presenter.notice(text, note: note, collapseAfter: OverlayPresenter.resultDisplayDuration)
    }
}
