import AppKit

/// The NSPanel side of the overlay as the presenter drives it —
/// `OverlayController` in the app, a recorder in the self-tests.
@MainActor protocol OverlaySurface: AnyObject {
    /// Order in at the resting pill size, click-through.
    func show()
    /// Order out, click-through, pill size; resets the model.
    func hide()
    func resize(to size: NSSize)
    func setInteractive(_ interactive: Bool)
}

/// Puts the overlay into a state — the model the SwiftUI views read plus
/// the panel's size and clickability, derived from that state — and owns
/// the timers around it (result auto-collapse, the stuck-pill ✕, the
/// hide-after-fade). The flows say what to show; this says how.
@MainActor final class OverlayPresenter {
    let model: AudioModel
    private let scheduler: MainScheduler
    private let makeSurface: () -> OverlaySurface
    /// Built on first use (the first hold), not at launch.
    private lazy var surface: OverlaySurface = makeSurface()

    /// How long a result box stays on screen before collapsing.
    static let resultDisplayDuration: TimeInterval = 6.0
    /// Assistant answers stay up longer — you need time to read them (dismiss
    /// early with the ✕ button).
    static let assistantDisplayDuration: TimeInterval = 15.0
    /// How long the dots may spin before the pill offers a ✕.
    static let stuckTranscribingSeconds: TimeInterval = 8
    /// A finished pill eases out this long before the panel hides.
    static let hideSoonSeconds: TimeInterval = 0.4

    /// Pending result auto-dismiss.
    private var collapseWork: DispatchWorkItem?
    /// Pending "offer a ✕" on the transcribing pill.
    private var stuckWork: DispatchWorkItem?

    init(model: AudioModel, scheduler: MainScheduler = DispatchMainScheduler.shared,
         makeSurface: @escaping () -> OverlaySurface) {
        self.model = model
        self.scheduler = scheduler
        self.makeSurface = makeSurface
    }

    var state: OverlayState { model.state }
    /// Nothing showing: hidden, or the pill easing out.
    var isIdle: Bool { model.state == .idle }

    // MARK: - Pills

    /// A session is capturing: the listening pill for `kind`, ordered in.
    func listening(_ kind: OverlayState.ListenKind) {
        switch kind {
        case .live: model.beginLiveDictation()
        case .dictation, .assistant: model.beginListening(assistant: kind == .assistant)
        }
        surface.show()
    }

    /// Enter the transcribing pill. It's click-through, so a decode or final
    /// pass that never returned left a pill nobody could close; past
    /// `stuckTranscribingSeconds` it grows a ✕ (→ the dismiss handler: queued
    /// dictations still type if they ever decode, a final pass types nothing).
    func transcribing() {
        model.beginTranscribing()
        stuckWork?.cancel()
        stuckWork = scheduler.after(Self.stuckTranscribingSeconds) { [weak self] in
            guard let self, self.model.state.isTranscribing else { return }
            self.model.offerTranscribingDismiss()
            self.surface.setInteractive(self.model.state.isInteractive)
        }
    }

    // MARK: - Boxes

    /// Grow the showing pill into a box (copy + ✕ clickable). Collapses
    /// after `collapseAfter`; nil leaves it up — and any pending collapse
    /// untouched — until something replaces it. Not ordered in: a box
    /// for an overlay the user already closed stays closed (`notice`
    /// orders in).
    func result(_ text: String, note: String? = nil, isError: Bool = false,
                collapseAfter: TimeInterval?) {
        model.showResult(text, isError: isError, note: note)
        render()
        if let collapseAfter { scheduleCollapse(after: collapseAfter) }
    }

    /// A short message in the result box (✕ closes it), shown whether or not
    /// the pill was already up.
    func notice(_ text: String, note: String? = nil, collapseAfter: TimeInterval = 5.0) {
        surface.show()
        result(text, note: note, collapseAfter: collapseAfter)
    }

    /// Switch to the streaming answer box. When continuing, `priorTurns`
    /// show above the new answer so it reads as one conversation.
    func streaming(priorTurns: [ChatTurn], question: String) {
        model.beginStreaming(priorTurns: priorTurns, question: question)
        render()
    }

    func updateStreaming(_ text: String) {
        model.updateStreaming(text)
    }

    /// Settle the streamed answer into its final box with a Continue footer.
    /// Chat transcripts keep the fixed scrolling box; a fresh single answer
    /// sizes to its text.
    func answer(_ text: String) {
        model.showAssistantResult(text)
        render()
        scheduleCollapse(after: Self.assistantDisplayDuration)
    }

    // MARK: - Hiding

    /// Let the pill ease out, then hide — unless something new is showing by then.
    func hideSoon() {
        model.finishListening()
        scheduler.after(Self.hideSoonSeconds) { [weak self] in
            guard let self else { return }
            guard self.isIdle else { return }
            self.surface.hide()   // hide() resets the model
        }
    }

    /// A new session supersedes the result box: its auto-collapse is moot.
    func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    /// Hide now (✕, Continue) — hide() resets the model.
    func dismiss() {
        cancelCollapse()
        collapse()
    }

    // MARK: - Private

    /// Size and clickability follow the state.
    private func render() {
        surface.resize(to: model.state.panelSize)
        surface.setInteractive(model.state.isInteractive)
    }

    private func scheduleCollapse(after seconds: TimeInterval) {
        collapseWork?.cancel()
        collapseWork = scheduler.after(seconds) { [weak self] in self?.collapse() }
    }

    private func collapse() {
        collapseWork = nil
        surface.hide()   // hide() resets the model
    }
}
