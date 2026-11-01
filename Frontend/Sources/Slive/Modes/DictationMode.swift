import Foundation

/// One thing a shortcut can do once its gesture goes live — dictate, ask
/// the assistant, stream live. `SessionCoordinator` decides *when*
/// (hold, tail, toggle, false start); the mode decides *what*.
@MainActor protocol DictationMode: AnyObject {
    /// The action this mode serves (its `ActionSpec` says how it's bound).
    static var action: HotkeyAction { get }
    /// The gesture went live: start capturing.
    func begin()
    /// The release, after the post-release tail: stop capturing and hand off.
    func end()
    /// A false start: discard the live capture completely — no
    /// transcription, no typing, no training capture.
    func cancel()
    /// ✕ (or quit): drop in-flight work that isn't spoken words. Released
    /// dictations still type.
    func dismiss()
    /// A recording or live stream of this mode's is running right now.
    var isCapturing: Bool { get }
}

extension DictationMode {
    var action: HotkeyAction { Self.action }
}

/// Every mode this build runs, by action — and the `SessionHandler` the
/// gesture machine drives: begin/end look the action up, abort and ✕ go to
/// every mode. An action this build can't run (Lite: the assistant) is
/// simply not registered, so its gestures do nothing.
///
/// Adding a mode:
/// 1. a `HotkeyAction` case and its `ActionSpec` (Hotkey/HotkeyAction.swift)
///    — shortcuts, cue, queue rule, required capability;
/// 2. a type conforming to `DictationMode` in Modes/, built from a
///    `ModeContext` (a hold-to-talk mode conforms to `RecordingRoute` and
///    lets `HoldCapture` record and decode for it);
/// 3. one `register` line in `standard(_:continuous:assistant:capabilities:)`.
@MainActor final class ModeRegistry: SessionHandler {
    private var modes: [HotkeyAction: DictationMode] = [:]
    /// The same modes in priority order (abort, ✕ and quit visit them in it).
    private var all: [DictationMode] = []
    private let capabilities: Capabilities
    private let work: InFlightWork

    init(capabilities: Capabilities, work: InFlightWork) {
        self.capabilities = capabilities
        self.work = work
    }

    /// The app's modes. The assistant is built only where it can run.
    static func standard(_ context: ModeContext, continuous: ContinuousDictation,
                         assistant: @autoclosure () -> AssistantService,
                         capabilities: Capabilities) -> ModeRegistry {
        let registry = ModeRegistry(capabilities: capabilities, work: context.work)
        registry.register(DictateMode(context))
        registry.register(AssistMode(context, assistant: assistant()))
        registry.register(StreamMode(context, continuous: continuous))
        return registry
    }

    /// Add `make()`'s mode — built only if this build offers its action.
    func register<M: DictationMode>(_ make: @autoclosure () -> M) {
        guard M.action.spec.isAvailable(in: capabilities) else { return }
        modes[M.action] = make()
        all = HotkeyAction.allCases.compactMap { modes[$0] }
    }

    func mode(for action: HotkeyAction) -> DictationMode? { modes[action] }

    /// The registered actions, in priority order.
    var actions: [HotkeyAction] { all.map(\.action) }

    /// ✕ or quit, for every mode.
    func dismissAll() {
        for mode in all { mode.dismiss() }
    }

    // MARK: - SessionHandler

    func beginSession(_ action: HotkeyAction) { modes[action]?.begin() }

    func endSession(_ action: HotkeyAction) { modes[action]?.end() }

    func abortSession() {
        work.cancelRequest()
        for mode in all { mode.cancel() }
        work.endDictationActivityIfIdle()   // the discarded fragment held it
    }

    var isCapturing: Bool { all.contains { $0.isCapturing } }
}
