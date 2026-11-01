import Foundation

/// What a hotkey gesture asks of the dictation flows: start capturing, the
/// release, or throw a false start away.
@MainActor protocol SessionHandler: AnyObject {
    /// Start capturing for `action` (record, or stream live).
    func beginSession(_ action: HotkeyAction)
    /// The release, after the post-release tail: stop capturing and hand off.
    func endSession(_ action: HotkeyAction)
    /// Discard the live session completely: no transcription, no typing, no
    /// training capture — the fragment never happened.
    func abortSession()
    /// A recording or live stream is running right now.
    var isCapturing: Bool { get }
}

/// The hotkey gesture state machine: hold to talk (armed after the hold
/// delay, released through a short tail), tap to toggle, and the rules
/// between them. Owns the gesture's timers and timestamps; the flows behind
/// `handler` do the capturing.
@MainActor final class SessionCoordinator {
    /// The mic stays open this long AFTER release so a final syllable still
    /// sounding at key-up isn't clipped. 0.1s since Sep 27, 2026 (was 0.3):
    /// `--bench-tail` on 300 recent dictations — the extra 0.2s was true
    /// silence in 42%, and cutting it changed an ending in 1 of 300 (0.3%,
    /// an already-garbled final word); Soumil releases the instant he stops
    /// speaking, so this is 0.2s off every dictation.
    static let postReleaseCaptureSeconds: TimeInterval = 0.10
    /// A double-tap may abort a hold session only this young — it is the
    /// first tap of the double, not a dictation someone is mid-sentence into.
    static let falseStartWindow: TimeInterval = 1.0

    /// What the gesture is waiting on. (Whether a session is capturing is
    /// the handler's to say.)
    enum Gesture: Equatable {
        case idle
        /// Held; recording begins only if still held after the delay.
        case arming(HotkeyAction)
        /// Released; the delayed stop runs after `postReleaseCaptureSeconds`
        /// (flushed early if a new hold begins).
        case tail(HotkeyAction)
    }

    weak var handler: SessionHandler?
    private let scheduler: MainScheduler
    private let holdDelay: () -> TimeInterval

    private(set) var gesture: Gesture = .idle
    /// The arm or the delayed stop, matching `gesture`.
    private var gestureWork: DispatchWorkItem?
    /// Which toggle session is live, if any. Toggle sessions reuse the exact
    /// hold machinery (begin/stop + the post-release capture); only who
    /// decides "release" differs — the second tap instead of a key-up.
    private(set) var toggleActive: HotkeyAction?
    /// Which shortcut is recording (the last one pressed).
    private(set) var currentAction: HotkeyAction = .dictate
    private var recordStart: Date?
    /// When the current continuous session began speaking (post hold-delay), so
    /// its pace can be measured on release.
    private var liveStart: Date?
    /// When the hotkey lifted — anchor for the always-on release→typed log.
    /// The flow that logs it clears it.
    var releasedAt: Date?

    init(scheduler: MainScheduler = DispatchMainScheduler.shared,
         holdDelay: @escaping () -> TimeInterval) {
        self.scheduler = scheduler
        self.holdDelay = holdDelay
    }

    var now: Date { scheduler.now }

    /// True while any recording/stream session is actually running.
    var isSessionLive: Bool {
        if case .tail = gesture { return true }
        return handler?.isCapturing ?? false
    }

    // MARK: - Timestamps the flows report

    func recordingStarted() { recordStart = now }

    /// Seconds since the recording started.
    var recordedSeconds: TimeInterval { recordStart.map { now.timeIntervalSince($0) } ?? 0 }

    func liveStarted() { liveStart = now }

    /// The live session's release: seconds it ran.
    func liveEnded() -> TimeInterval {
        let held = liveStart.map { now.timeIntervalSince($0) } ?? 0
        liveStart = nil
        return held
    }

    /// The live stream couldn't start: no toggle session is live.
    func liveFailed() {
        toggleActive = nil
        liveStart = nil
    }

    /// Nothing started (mic failed) or ✕: no toggle session is live — else
    /// the next tap is eaten as this session's "stop".
    func endToggle() { toggleActive = nil }

    // MARK: - Hold-to-talk

    func keyDown(_ action: HotkeyAction) {
        // A held key takes over from a live toggle session: close the toggle
        // (schedules its stop), then flush so the new hold starts clean.
        if toggleActive != nil {
            toggleActive = nil
            keyUp()
        }
        // A delayed stop may still be pending from the previous release — flush
        // it now (stop + hand off to transcription immediately) so the new hold
        // starts from a clean state instead of colliding with a live session.
        flushPendingStop()
        // Arm: recording begins only if the key is still held after the delay.
        gestureWork?.cancel()
        currentAction = action
        gesture = .arming(action)
        gestureWork = scheduler.after(holdDelay()) { [weak self] in
            guard let self else { return }
            self.settle()
            self.handler?.beginSession(action)
        }
    }

    func keyUp() {
        if case .arming = gesture {
            // Released before the hold threshold → do nothing at all.
            gestureWork?.cancel()
            settle()
            return
        }
        // Keep capturing briefly (postReleaseCaptureSeconds) so a final
        // syllable still sounding at key-up isn't clipped.
        // The pill stays visible and naturally changes to its processing state
        // when the delayed stop begins transcription.
        gestureWork?.cancel()
        releasedAt = now   // anchors the release→typed timing log
        let action = currentAction
        gesture = .tail(action)
        gestureWork = scheduler.after(Self.postReleaseCaptureSeconds) { [weak self] in
            guard let self else { return }
            self.settle()
            self.handler?.endSession(action)
        }
    }

    /// Run the pending delayed stop right now (if any) — used when a new hold
    /// begins inside the release-tail window, so sessions never overlap.
    private func flushPendingStop() {
        guard case .tail = gesture else { return }
        gestureWork?.cancel()
        settle()
        handler?.endSession(currentAction)
    }

    // MARK: - Tap-to-toggle (click to start, click again to stop)

    func toggleTapped(_ action: HotkeyAction) {
        // A double-tap bind shares its gesture with a hold bind (fn hold vs
        // fn-fn): the second press also armed a pending hold — kill it, the
        // double-tap owns this press.
        if case .arming = gesture {
            gestureWork?.cancel()
            settle()
        }
        // Second tap of the live toggle session → the release.
        if toggleActive == action {
            toggleActive = nil
            keyUp()
            return
        }
        guard toggleActive == nil else {
            Log.hotkey("toggle \(action) ignored — another toggle session is live")
            return
        }
        // Taps slower than holdActivationDelay make the FIRST tap of a double
        // mature into a real hold session — by the second tap it's recording
        // (or already winding down / transcribing a short fragment). The
        // completed double outranks that false start: abort it, type nothing
        // from it, and give the mic to the toggle. Age-gated so a stray
        // double-tap can never kill a long-running real dictation.
        if isSessionLive {
            guard sessionStartedRecently(within: Self.falseStartWindow) else {
                Log.hotkey("toggle \(action) ignored — a real session is live")
                return
            }
            abortFalseStartSession()
        }
        toggleActive = action
        currentAction = action
        // No hold-activation delay for a tap: the tap IS deliberate.
        handler?.beginSession(action)
        // Nothing started (mic blocked, model not ready, stream refused): no
        // toggle is live — else the next tap is eaten as this one's "stop".
        if !(handler?.isCapturing ?? false) { toggleActive = nil }
    }

    /// True when the live session began moments ago — i.e. it is the first
    /// tap of this double, not a dictation someone is mid-sentence into.
    private func sessionStartedRecently(within interval: TimeInterval) -> Bool {
        if let t = recordStart, now.timeIntervalSince(t) < interval { return true }
        if let t = liveStart, now.timeIntervalSince(t) < interval { return true }
        if case .tail = gesture { return true }   // tap-1's delayed stop is still queued
        return false
    }

    /// Discard a false-start session completely: no transcription, no typing,
    /// no training capture — the fragment never happened.
    private func abortFalseStartSession() {
        gestureWork?.cancel()
        settle()
        handler?.abortSession()
        Log.hotkey("false-start hold session aborted by double-tap")
    }

    /// The arm or delayed stop has run or been cancelled.
    private func settle() {
        gestureWork = nil
        gesture = .idle
    }
}
