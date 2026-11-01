import ApplicationServices
import Foundation

/// The old one-stop typing API, kept as a thin facade while call sites move
/// to the sinks. Each member forwards, unchanged, to where its logic lives:
/// - `TypingSink` — the `TextSink`/`LiveTextSink` that types at the caret
/// - `TypingPolicy` — may we type (secure input, password fields, fail-open)
/// - `FocusProbe` — bounded AX reads of what has focus
/// - `SyntheticTyper` — CGEvent posting and the typing queue
/// - `DeliveryVerifier` — the after-the-fact receipt
enum PasteEngine {
    typealias StreamTarget = Slive.StreamTarget
    typealias FocusKind = FocusProbe.FocusKind

    static let syntheticMarker = SyntheticTyper.syntheticMarker
    static let maxUnicodeUnitsPerEvent = SyntheticTyper.maxUnicodeUnitsPerEvent
    static let axTimeout = FocusProbe.axTimeout
    static let descendantWalkBudget = FocusProbe.descendantWalkBudget

    // Typing
    static func isStillStreamTarget(_ target: StreamTarget) -> Bool {
        TypingSink().stillOurs(LiveStreamHandle(allowed: true, target: target))
    }
    static func postUnicode(_ s: String) { SyntheticTyper.postUnicode(s) }
    static func postBackspace() { SyntheticTyper.postBackspace() }
    static func unicodeChunks(_ s: String, maxUnits: Int = maxUnicodeUnitsPerEvent) -> [String] {
        SyntheticTyper.unicodeChunks(s, maxUnits: maxUnits)
    }

    // Policy
    static func secureInputBlocksTyping() -> Bool { TypingPolicy.secureInputBlocksTyping() }
    static func typingBlockedNote(accessibility: Bool, secureInput: Bool) -> String? {
        TypingPolicy.typingBlockedNote(accessibility: accessibility, secureInput: secureInput)
    }
    static func shouldDispatch(role: String?) -> Bool { TypingPolicy.shouldDispatch(role: role) }
    static func deliveryChanged(beforeValue: String?, beforeRange: CFRange?,
                                afterValue: String?, afterRange: CFRange?) -> Bool {
        DeliveryVerifier.deliveryChanged(beforeValue: beforeValue, beforeRange: beforeRange,
                                         afterValue: afterValue, afterRange: afterRange)
    }

    // Focus
    static func probeFocus() -> FocusProbe.Result { FocusProbe.probe() }
    static func focusedElement() -> AXUIElement? { FocusProbe.focusedElement() }
    static func isSecure(_ element: AXUIElement) -> Bool { FocusProbe.isSecure(element) }
    static func focusKind(role: String?) -> FocusKind { FocusProbe.focusKind(role: role) }
    static func axSaysNothingFocused(_ error: AXError) -> Bool { FocusProbe.axSaysNothingFocused(error) }
    static func confirmsNoFocus(windowError: AXError) -> Bool { FocusProbe.confirmsNoFocus(windowError: windowError) }
    static func isLazyAXBundle(identifier: String?, hasElectronFramework: Bool) -> Bool {
        FocusProbe.isLazyAXBundle(identifier: identifier, hasElectronFramework: hasElectronFramework)
    }
}
