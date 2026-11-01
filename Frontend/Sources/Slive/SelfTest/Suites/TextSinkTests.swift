import ApplicationServices
import Foundation
import SliveTestKit

/// Typing policy, sinks, and LiveTypist driven through a fake field
@MainActor
enum TextSinkTests {
    static let suite = TestSuite(name: "Text sinks") { t in
        print("[Text sinks]")
        policy(&t)
        sinks(&t)
        liveTypist(&t)
    }

    // MARK: Policy

    private static func policy(_ t: inout Checks) {
        typealias P = TypingPolicy
        let field = P.Focus.element(role: kAXTextFieldRole as String, isSecure: false)

        // Order + laziness: no secure-input read without Accessibility, no
        // probe while secure input blocks.
        var secureRead = false, probed = false
        let noAX = P.verdict(accessibility: false,
                             secureInput: { secureRead = true; return false }(),
                             focus: { probed = true; return field })
        t.check(noAX == .refuse(reason: nil, note: "Not typed · Accessibility is off") && !secureRead && !probed,
                "Accessibility off refuses silently, before any other read")
        let secure = P.verdict(accessibility: true, secureInput: true,
                               focus: { probed = true; return field })
        t.check(secure == .refuse(reason: "secure event input on", note: "Not typed · secure input is on") && !probed,
                "secure input refuses with its note and never probes focus")

        t.equal(P.verdict(accessibility: true, secureInput: false, focus: { field }),
                .type(verifiable: true, failOpen: false), "text field types and is verifiable")
        t.equal(P.verdict(accessibility: true, secureInput: false,
                          focus: { .element(role: nil, isSecure: true) }),
                .refuse(reason: "secure field", note: nil), "password field refused, no copy-box note")
        t.equal(P.verdict(accessibility: true, secureInput: false,
                          focus: { .element(role: kAXButtonRole as String, isSecure: false) }),
                .refuse(reason: "non-text focus (AXButton)", note: nil), "button focus refused")
        t.equal(P.verdict(accessibility: true, secureInput: false, focus: { .none }),
                .refuse(reason: "nothing has keyboard focus", note: nil), "corroborated void refused")
        t.equal(P.verdict(accessibility: true, secureInput: false, focus: { .unknown }),
                .type(verifiable: false, failOpen: true), "AX can't tell → fail open (Electron)")
        t.equal(P.verdict(accessibility: true, secureInput: false,
                          focus: { .element(role: kAXGroupRole as String, isSecure: false) }),
                .type(verifiable: false, failOpen: false), "focused group types, unverified")
        t.equal(P.verdict(accessibility: true, secureInput: false,
                          focus: { .element(role: nil, isSecure: false) }),
                .type(verifiable: false, failOpen: false), "unreadable role fails open")

        t.equal(P.deliverability(.type(verifiable: true, failOpen: false)), .ok, "typed verdict → .ok")
        t.equal(P.deliverability(.type(verifiable: false, failOpen: true)), .unknown, "fail-open verdict → .unknown")
        t.equal(P.deliverability(secure), .blocked(note: "Not typed · secure input is on"), "refusal carries its note")
        t.check(Deliverability.unknown.allowsDelivery && !Deliverability.blocked(note: nil).allowsDelivery,
                "unknown still delivers; blocked doesn't")

        // Secure input counts only when the frontmost app holds it (Nov 5:
        // Terminal's Secure Keyboard Entry blocked typing everywhere).
        t.check(!P.secureInputBlocks(enabled: false, owner: 42, frontmost: 42), "secure input off never blocks")
        t.check(P.secureInputBlocks(enabled: true, owner: 42, frontmost: 42), "frontmost app holds it → blocks")
        t.check(!P.secureInputBlocks(enabled: true, owner: 7, frontmost: 42),
                "a background app's secure input doesn't block")
        t.check(P.secureInputBlocks(enabled: true, owner: nil, frontmost: 42), "unreadable holder → blocks")
        t.check(!P.secureInputBlocks(enabled: true, owner: 7, frontmost: nil), "no frontmost app → holder isn't it")

        // Delivery receipt: an unreadable field fails open (no copy box).
        let r = CFRange(location: 3, length: 0)
        t.equal(DeliveryVerifier.receipt(beforeValue: "abc", beforeRange: r, afterValue: nil, afterRange: nil),
                .unknown, "unreadable field after typing → unknown, no copy box")
        t.equal(DeliveryVerifier.receipt(beforeValue: "abc", beforeRange: r, afterValue: "abcd", afterRange: r),
                .landed, "value changed → landed")
        t.equal(DeliveryVerifier.receipt(beforeValue: "abc", beforeRange: r, afterValue: "abc", afterRange: r),
                .notYet, "nothing moved → not yet")
    }

    // MARK: Sinks

    private static func sinks(_ t: inout Checks) {
        let clip = ClipboardSink()
        t.equal(clip.canDeliver(), .blocked(note: nil), "clipboard sink: blocked by choice, no note")
        var failed = false
        t.check(!clip.deliver("hello", onDeliveryFailure: { failed = true }) && !failed,
                "clipboard sink never types and never reports a failed delivery")
        t.check(!clip.beginStream().allowed, "clipboard sink never streams")
        t.check(!clip.deliver(""), "empty text isn't delivered")
        t.equal(PasteEngine.syntheticMarker, SyntheticTyper.syntheticMarker, "facade keeps the synthetic marker")
    }

    // MARK: LiveTypist

    private static func liveTypist(_ t: inout Checks) {
        // Revisions converge; the field mirrors what the typist believes it typed.
        do {
            let field = FakeField()
            let typist = LiveTypist(sink: field)
            typist.start(field.beginStream(), cps: 1000)
            typist.setTarget("hello wrld")
            typist.setTarget("hello world, how are")
            typist.setTarget("hello world, how are you")
            let result = finish(typist)
            t.equal(field.text, "hello world, how are you", "live typing converges on the target")
            t.check(result.text == field.text && !result.focusLost, "finish reports exactly the field")
        }
        // Slow pacing: finish snaps the rest in at once.
        do {
            let field = FakeField()
            let typist = LiveTypist(sink: field)
            typist.start(field.beginStream(), cps: 1)
            typist.setTarget("the final pass")
            _ = finish(typist)
            t.equal(field.text, "the final pass", "finish snaps a paced reveal to the full target")
        }
        // A revision behind the freeze never rewrites frozen text, and the
        // seam neither drops nor doubles a character.
        do {
            let field = FakeField()
            let typist = LiveTypist(sink: field)
            let tail = String(repeating: "and then the next sentence. ", count: 4)
            typist.start(field.beginStream(), cps: 1000)
            typist.setTarget("a lot of " + tail)
            typist.setTarget("alot of " + tail + "end")
            let result = finish(typist)
            t.check(field.text == result.text && field.text.hasSuffix(tail + "end")
                    && field.text.hasPrefix("a lot of "),
                    "freeze holds and the seam stays exact", field.text)
        }
        // Nov 5: cancel during the final pass must not retype everything.
        do {
            let field = FakeField()
            let typist = LiveTypist(sink: field)
            typist.start(field.beginStream(), cps: 1000)
            typist.setTarget("hello")
            typist.cancel()
            typist.setTarget("hello world")
            let result = finish(typist)
            t.check(field.text == "hello" && field.typedCount == 5 && result.text.isEmpty,
                    "cancel during the final pass doesn't retype", "field=\(field.text)")
        }
        // Focus leaves the field: no backspaces into the new target.
        do {
            let field = FakeField()
            field.lostWhenFieldIs = "hello"
            let typist = LiveTypist(sink: field)
            typist.start(field.beginStream(), cps: 1000)
            typist.setTarget("hello")
            typist.setTarget("help")
            let result = finish(typist)
            t.check(field.text == "hello" && result.focusLost && result.text == "hello",
                    "focus loss stops typing and reports it", "field=\(field.text)")
        }
        // Not allowed this session: nothing is ever posted.
        do {
            let field = FakeField()
            let typist = LiveTypist(sink: field)
            typist.start(LiveStreamHandle(allowed: false, target: nil), cps: 1000)
            typist.setTarget("nothing")
            let result = finish(typist)
            t.check(field.calls == 0 && result.text.isEmpty, "disallowed session never touches the field")
        }
    }

    /// Blocks until `finish()` returns. Safe: the typist works on its own
    /// queue, never the main thread.
    private static func finish(_ typist: LiveTypist) -> LiveTypist.FinishResult {
        final class Box: @unchecked Sendable { var result: LiveTypist.FinishResult? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.result = await typist.finish()
            done.signal()
        }
        done.wait()
        return box.result!
    }
}

/// A text field in memory. Called on the typist's queue; read from main
/// after `finish()`.
private final class FakeField: LiveTextSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    private var _typed = 0
    private var _calls = 0
    /// `stillOurs` answers false once the field holds exactly this.
    var lostWhenFieldIs: String?

    var text: String { lock.withLock { _text } }
    var typedCount: Int { lock.withLock { _typed } }
    var calls: Int { lock.withLock { _calls } }

    func beginStream() -> LiveStreamHandle {
        LiveStreamHandle(allowed: true, target: StreamTarget(pid: 1, element: nil))
    }

    func replace(backspaces: Int, insert: String) {
        lock.withLock {
            _calls += 1
            _text.removeLast(min(backspaces, _text.count))
            _text += insert
            _typed += insert.count
        }
    }

    func stillOurs(_ handle: LiveStreamHandle) -> Bool {
        lock.withLock { lostWhenFieldIs.map { $0 != _text } ?? true }
    }
}
