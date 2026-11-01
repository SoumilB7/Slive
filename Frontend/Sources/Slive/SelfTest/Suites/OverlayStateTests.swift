import AppKit
import SliveTestKit

/// Overlay state: derived panel size / clickability, the model's
/// transitions, the presenter's timers, the meter's easing.
@MainActor
enum OverlayStateTests {
    /// Records what the presenter asked of the panel; `hide` resets the
    /// model, as OverlayController's does.
    final class FakeSurface: OverlaySurface {
        let model: AudioModel
        var calls: [String] = []
        var size: NSSize = .zero
        var interactive = false
        init(model: AudioModel) { self.model = model }
        func show() { calls.append("show"); interactive = false; size = OverlayMetrics.pillSize }
        func hide() { calls.append("hide"); interactive = false; size = OverlayMetrics.pillSize; model.reset() }
        func resize(to size: NSSize) { calls.append("resize"); self.size = size }
        func setInteractive(_ interactive: Bool) { self.interactive = interactive }
    }

    static func make() -> (OverlayPresenter, FakeSurface, ManualScheduler) {
        let clock = ManualScheduler()
        let model = AudioModel()
        let surface = FakeSurface(model: model)
        return (OverlayPresenter(model: model, scheduler: clock) { surface }, surface, clock)
    }

    static let suite = TestSuite(name: "Overlay state") { t in
        print("[Overlay state]")
        let pill = OverlayMetrics.pillSize
        let answerText = "An answer."
        let chat = OverlayResult.Answer(streaming: false, priorTurns: [ChatTurn(role: "user", text: "q")], question: "q2")

        // Derivations.
        for s in [OverlayState.idle, .listening(.dictation), .listening(.assistant), .listening(.live),
                  .transcribing(stuck: false)] {
            t.check(s.panelSize == pill && !s.isInteractive, "\(s): pill-sized, click-through")
        }
        t.check(OverlayState.transcribing(stuck: true).isInteractive, "a stuck transcribing pill is clickable (its ✕)")
        let plain = OverlayState.result(OverlayResult(text: "hi", note: "Not typed"))
        t.check(plain.panelSize == OverlayMetrics.panelSize(for: "hi", note: "Not typed") && plain.isInteractive,
                "a box sizes to its text and note, clickable")
        t.check(plain.result?.showsContinue == false, "a plain box has no Continue footer")
        let streaming = OverlayState.result(OverlayResult(text: "partial", answer: .init(streaming: true)))
        t.check(streaming.panelSize == OverlayMetrics.streamingPanelSize && streaming.result?.showsContinue == false,
                "a streaming answer uses the fixed box, no Continue yet")
        let answer = OverlayState.result(OverlayResult(text: answerText, answer: .init(streaming: false)))
        t.check(answer.panelSize == OverlayMetrics.assistantPanelSize(for: answerText)
                && answer.result?.showsContinue == true, "a final answer sizes to its text plus the Continue footer")
        let chatAnswer = OverlayState.result(OverlayResult(text: answerText, answer: chat))
        t.check(chatAnswer.panelSize == OverlayMetrics.assistantStreamingPanelSize
                && chatAnswer.result?.boxSize == OverlayMetrics.streamingBoxSize,
                "a chat answer keeps the fixed scrolling box")
        t.check(OverlayState.listening(.dictation).rank == OverlayState.listening(.live).rank
                && streaming.rank == answer.rank, "the animation rank ignores listen kind and streamed text")
        t.check(plain.showsText && !OverlayState.listening(.dictation).showsText, "only boxes show text")

        // The model's transitions.
        let model = AudioModel()
        model.beginListening(assistant: true)
        t.equal(model.state, .listening(.assistant), "assistant listening")
        model.offerTranscribingDismiss()
        t.equal(model.state, .listening(.assistant), "no ✕ offered outside transcribing")
        model.beginTranscribing()
        model.offerTranscribingDismiss()
        t.equal(model.state, .transcribing(stuck: true), "a stuck transcribing pill offers its ✕")
        model.beginStreaming(priorTurns: chat.priorTurns, question: "q2")
        model.updateStreaming("part")
        t.equal(model.state.result?.text, "part", "streamed text updates the box")
        model.showAssistantResult(answerText)
        t.check(model.state.result?.answer?.priorTurns == chat.priorTurns
                && model.state.result?.answer?.question == "q2" && model.state.result?.isStreaming == false,
                "the final answer keeps the chat transcript")
        model.updateStreaming("late token")
        t.equal(model.state.result?.text, answerText, "a token after the answer settled is ignored")
        model.showResult("plain", isError: true)
        t.check(model.state.result?.answer == nil && model.state.result?.isError == true,
                "a plain result drops the chat")
        model.reset()
        t.check(model.state == .idle && model.levels.allSatisfy { $0 == 0 }, "reset is idle and silent")

        // The presenter.
        do {
            let (p, surface, clock) = make()
            p.notice("No sound.")
            t.check(surface.calls.first == "show" && surface.size == p.state.panelSize && surface.interactive,
                    "a notice orders in, grows the panel, clickable")
            clock.advance(by: 4.9)
            t.check(!surface.calls.contains("hide"), "a notice stays up 5s")
            clock.advance(by: 0.2)
            t.check(surface.calls.last == "hide" && p.isIdle, "then collapses")
        }
        do {
            let (p, surface, clock) = make()
            p.listening(.dictation)
            p.result("Loading model.", collapseAfter: nil)
            clock.advance(by: 60)
            t.check(!surface.calls.contains("hide"), "a box without a collapse stays until replaced")
            p.notice("x")
            p.cancelCollapse()
            clock.advance(by: 60)
            t.check(!surface.calls.contains("hide"), "a new session cancels the pending collapse")
        }
        do {
            let (p, surface, clock) = make()
            p.listening(.dictation)
            p.hideSoon()
            clock.advance(by: 0.3)
            p.listening(.dictation)
            clock.advance(by: 1)
            t.check(!surface.calls.contains("hide") && p.state == .listening(.dictation),
                    "hide-soon spares a session that started meanwhile")
            p.hideSoon()
            clock.advance(by: OverlayPresenter.hideSoonSeconds)
            t.equal(surface.calls.last, "hide", "hide-soon hides an idle pill after the fade")
        }
        do {
            let (p, surface, clock) = make()
            p.listening(.dictation)
            p.transcribing()
            clock.advance(by: OverlayPresenter.stuckTranscribingSeconds - 1)
            t.check(!surface.interactive, "the transcribing pill is click-through at first")
            clock.advance(by: 1)
            t.check(p.state == .transcribing(stuck: true) && surface.interactive, "after 8s it offers a ✕")
            p.transcribing()
            p.result("text", collapseAfter: nil)
            clock.advance(by: OverlayPresenter.stuckTranscribingSeconds)
            t.check(p.state.result != nil, "a pill that moved on gets no ✕")
        }
        do {
            let (p, surface, clock) = make()
            p.listening(.assistant)
            p.streaming(priorTurns: [], question: "q")
            t.check(surface.size == OverlayMetrics.streamingPanelSize && surface.interactive,
                    "streaming opens the fixed answer box")
            p.answer(answerText)
            t.equal(surface.size, OverlayMetrics.assistantPanelSize(for: answerText), "the answer settles to its size")
            clock.advance(by: OverlayPresenter.assistantDisplayDuration - 1)
            t.check(!surface.calls.contains("hide"), "answers stay up longer")
            p.dismiss()
            t.check(surface.calls.last == "hide" && p.isIdle, "✕ hides at once")
            clock.advance(by: 5)
            t.equal(surface.calls.filter { $0 == "hide" }.count, 1, "a dismissed box doesn't collapse again")
        }

        // The meter.
        var meter = MeterEasing(bandCount: 5)
        let floor = meter.step(listening: true)
        t.check(floor.allSatisfy { $0 > 0 }, "a listening pill keeps a visible floor in silence")
        meter.push([0.5, 0.5, 0.5, 0.5, 0.5], rms: 0.05)
        _ = meter.step(listening: true)
        t.check(meter.glow > 0.3, "speech raises the bars fast")
        meter.silence()
        for _ in 0..<60 { _ = meter.step(listening: false) }
        t.check(meter.isFadedOut, "silence fades them out within a second")
    }
}
