import ApplicationServices
import Foundation

/// Types transcripts into whatever currently has keyboard focus, using pure
/// synthetic keystrokes — the same trust model as the user's own keyboard.
///
/// ## Why there is deliberately NO "is this a text field?" detection
///
/// We used to classify the focused element via Accessibility (role, settable
/// value, caret — later even waking Electron's lazily-built AX tree) and only
/// type if it "looked editable". That detection produced false refusals in
/// exactly the fields that matter most — Chromium/Electron webview inputs
/// (VS Code, the Claude Code extension, browsers), especially right after the
/// target app was relaunched: AX swore there was no text box while the keyboard
/// typed into it perfectly. Synthetic keystrokes ARE keyboard input and need no
/// AX cooperation, so gating them on an AX opinion was all downside. Removed
/// entirely; the user aims dictation with their caret, same as their keyboard.
///
/// The AX reads kept (`TypingPolicy`) are conservative, positive-only guards:
/// refuse a password field, and fall back to the copy box when focus is
/// definitely on a non-text target. Unknown/asleep AX trees still fail open,
/// so they cannot block typing into Electron.
struct TypingSink: TextSink, LiveTextSink {

    // MARK: TextSink

    /// Hops to the main thread for the AX read.
    func canDeliver() -> Deliverability {
        Self.onMain { TypingPolicy.deliverability(Self.judge(log: "typing").verdict) }
    }

    /// Type `text` at the caret, wherever it is.
    ///
    /// - Returns: `true` when typing was dispatched; `false` for empty text,
    ///   missing Accessibility permission, a positively-identified password
    ///   field, or a positively-identified non-text target. Unknown/broken AX
    ///   trees still fail open so Electron fields are never falsely refused.
    func deliver(_ text: String, onDeliveryFailure: @escaping () -> Void) -> Bool {
        guard !text.isEmpty else { return false }
        // The AX read and event posting belong on the main thread.
        return Self.onMain { Self.performInsert(text, onDeliveryFailure: onDeliveryFailure) }
    }

    // MARK: LiveTextSink

    func beginStream() -> LiveStreamHandle {
        let allowed = Self.canStream()
        return LiveStreamHandle(allowed: allowed, target: allowed ? Self.currentTarget() : nil)
    }

    func replace(backspaces: Int, insert: String) {
        for _ in 0..<backspaces { SyntheticTyper.postBackspace() }   // instant
        if !insert.isEmpty { SyntheticTyper.postUnicode(insert) }   // instant
    }

    /// Cheap — two to four AX reads, no tree walk — so it can run before
    /// every burst, from the typist's queue (AX reads are thread-safe; no main
    /// hop, which would stall typing behind UI work). Unknown answers fail open.
    func stillOurs(_ handle: LiveStreamHandle) -> Bool {
        guard let target = handle.target else { return true }
        // A password field took focus (Chrome/Electron ones don't always
        // show as secure in AX, but they do switch secure input on).
        if TypingPolicy.secureInputBlocksTyping() { return false }
        return FocusProbe.isStillFocused(on: target)
    }

    // MARK: Checks

    /// Whether we may stream-type right now: Accessibility granted (needed to
    /// post events at all) and the focused element is not a password field.
    /// Checked once at the start of a live dictation session. Safe to call from
    /// any thread — it hops to the main thread for the AX read.
    static func canStream() -> Bool {
        onMain { judge(log: "stream").verdict.allowsTyping }
    }

    /// Snapshot the current focus target (call right after `canStream()`).
    static func currentTarget() -> StreamTarget? {
        onMain(FocusProbe.currentTarget)
    }

    private static func performInsert(_ text: String,
                                      onDeliveryFailure: @escaping () -> Void) -> Bool {
        let (verdict, element) = judge(log: "insert")
        guard case .type(let verifiable, _) = verdict else { return false }
        let snapshot = verifiable ? element.flatMap(DeliveryVerifier.snapshot(of:)) : nil
        SyntheticTyper.enqueue(text) {
            guard let snapshot else { return }
            DeliveryVerifier.verify(snapshot, onFailure: onDeliveryFailure)
        }
        return true
    }

    /// Gather the facts lazily (in the policy's order), decide, and log a
    /// refusal as "<log> refused — <reason>". Main thread.
    private static func judge(log: String?) -> (verdict: TypingPolicy.Verdict, element: AXUIElement?) {
        var element: AXUIElement?
        let verdict = TypingPolicy.verdict(
            accessibility: AXIsProcessTrusted(),
            secureInput: TypingPolicy.secureInputBlocksTyping(),
            focus: {
                switch FocusProbe.probe() {
                case .element(let e):
                    element = e
                    let secure = FocusProbe.isSecure(e)
                    return .element(role: secure ? nil : AXRead.string(e, kAXRoleAttribute as String),
                                    isSecure: secure)
                case .none: return .none
                case .unknown: return .unknown
                }
            })
        if let log, case .refuse(let reason?, _) = verdict {
            Log.paste("\(log) refused — \(reason)")
        }
        return (verdict, element)
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}
