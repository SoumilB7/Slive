import Foundation
import SliveTestKit

/// Hotkey gesture rules (hold arm, release tail, toggle, false start), on a
/// manual clock with a fake flow behind them.
@MainActor
enum SessionCoordinatorTests {
    /// Records what the coordinator asked for; reports the timestamps the
    /// real flows report.
    final class FakeFlows: SessionHandler {
        weak var session: SessionCoordinator?
        var log: [String] = []
        var capturing = false
        /// False: the session fails to start (mic blocked, model not ready).
        var starts = true

        func beginSession(_ action: HotkeyAction) {
            log.append("begin \(action)")
            guard starts else { return }
            capturing = true
            if action == .stream { session?.liveStarted() } else { session?.recordingStarted() }
        }
        func endSession(_ action: HotkeyAction) {
            log.append("end \(action)")
            capturing = false
        }
        func abortSession() {
            log.append("abort")
            capturing = false
        }
        var isCapturing: Bool { capturing }
    }

    static let holdDelay: TimeInterval = 0.15

    static func make() -> (SessionCoordinator, FakeFlows, ManualScheduler) {
        let clock = ManualScheduler()
        let session = SessionCoordinator(scheduler: clock, holdDelay: { holdDelay })
        let flows = FakeFlows()
        flows.session = session
        session.handler = flows
        return (session, flows, clock)
    }

    static let suite = TestSuite(name: "Session coordinator") { t in
        print("[Session coordinator]")
        t.equal(SessionCoordinator.postReleaseCaptureSeconds, 0.10, "the release tail is 0.10s")

        do {
            let (s, f, clock) = make()
            s.keyDown(.dictate)
            t.equal(s.gesture, .arming(.dictate), "a press arms")
            clock.advance(by: 0.1)
            s.keyUp()
            clock.advance(by: 1)
            t.check(f.log.isEmpty && s.gesture == .idle, "a tap shorter than the hold delay starts nothing")
        }

        do {
            let (s, f, clock) = make()
            s.keyDown(.dictate)
            clock.advance(by: holdDelay)
            t.equal(f.log, ["begin dictate"], "a hold past the delay begins once")
            clock.advance(by: 2)
            s.keyUp()
            t.equal(s.gesture, .tail(.dictate), "release starts the tail")
            t.check(s.isSessionLive, "the tail counts as a live session")
            t.equal(s.releasedAt, clock.now, "release anchors the release→typed timing")
            clock.advance(by: 0.05)
            t.equal(f.log, ["begin dictate"], "the mic stays open through the tail")
            clock.advance(by: 0.06)
            t.equal(f.log, ["begin dictate", "end dictate"], "the stop runs after the tail")
            t.check(s.gesture == .idle && !s.isSessionLive, "back to idle after the stop")
        }

        do {
            let (s, f, clock) = make()
            s.keyDown(.dictate)
            clock.advance(by: 1)
            s.keyUp()
            clock.advance(by: 0.05)
            s.keyDown(.assist)
            t.equal(f.log, ["begin dictate", "end dictate"], "a new hold inside the tail flushes the stop first")
            t.equal(s.gesture, .arming(.assist), "then arms the new hold")
            t.equal(s.currentAction, .assist, "the new press is the current action")
            clock.advance(by: 1)
            t.equal(f.log, ["begin dictate", "end dictate", "begin assist"], "the flushed stop never runs twice")
        }

        do {
            let (s, f, clock) = make()
            s.toggleTapped(.dictate)
            t.equal(f.log, ["begin dictate"], "a toggle tap starts with no hold delay")
            t.equal(s.toggleActive, .dictate, "the toggle session is live")
            s.toggleTapped(.stream)
            t.equal(f.log, ["begin dictate"], "another toggle while one is live is ignored")
            clock.advance(by: 3)
            s.toggleTapped(.dictate)
            t.check(s.toggleActive == nil && s.gesture == .tail(.dictate), "the second tap is the release")
            clock.advance(by: 0.2)
            t.equal(f.log, ["begin dictate", "end dictate"], "the toggle stops after the same tail")
        }

        do {
            let (s, f, _) = make()
            f.starts = false
            s.toggleTapped(.stream)
            t.equal(s.toggleActive, nil, "a toggle whose session didn't start isn't live")
            f.starts = true
            s.toggleTapped(.stream)
            t.equal(f.log, ["begin stream", "begin stream"], "so the next tap starts again, not stops")
        }

        do {
            let (s, f, clock) = make()
            s.keyDown(.dictate)
            s.toggleTapped(.dictate)
            clock.advance(by: 1)
            t.equal(f.log, ["begin dictate"], "a double-tap kills the hold armed by its press")
        }

        do {
            // Slow double-tap: tap 1 matured into a hold and is in its tail.
            let (s, f, clock) = make()
            s.keyDown(.dictate)
            clock.advance(by: holdDelay)
            clock.advance(by: 0.15)
            s.keyUp()
            clock.advance(by: 0.05)
            s.toggleTapped(.dictate)
            t.equal(f.log, ["begin dictate", "abort", "begin dictate"],
                    "a double-tap aborts the false-start hold and takes the mic")
            clock.advance(by: 1)
            t.check(!f.log.contains("end dictate"), "the false start's stop never runs")
            t.equal(s.toggleActive, .dictate, "the toggle owns the session")
        }

        do {
            let (s, f, clock) = make()
            s.keyDown(.dictate)
            clock.advance(by: holdDelay)
            clock.advance(by: 0.5)
            s.toggleTapped(.stream)
            t.equal(f.log, ["begin dictate", "abort", "begin stream"], "a young recording is a false start")
        }

        do {
            let (s, f, clock) = make()
            s.keyDown(.dictate)
            clock.advance(by: holdDelay)
            clock.advance(by: SessionCoordinator.falseStartWindow + 0.5)
            s.toggleTapped(.dictate)
            t.check(f.log == ["begin dictate"] && s.toggleActive == nil,
                    "a stray double-tap never kills a long-running dictation")
        }

        do {
            let (s, f, clock) = make()
            s.toggleTapped(.stream)
            clock.advance(by: 4)
            s.keyDown(.dictate)
            t.equal(f.log, ["begin stream", "end stream"], "a held key closes a live toggle at once")
            t.check(s.toggleActive == nil && s.gesture == .arming(.dictate), "and arms its own hold")
            clock.advance(by: holdDelay)
            t.equal(f.log.last, "begin dictate", "the hold then begins")
        }

        do {
            let (s, f, clock) = make()
            s.toggleTapped(.stream)
            t.equal(f.log, ["begin stream"], "a stream toggle begins at once")
            clock.advance(by: 2.5)
            t.equal(s.liveEnded(), 2.5, "a live session's held time is measured from its start")
            t.equal(s.liveEnded(), 0, "and read once")
        }
    }
}
