import ApplicationServices
import Foundation

/// AX-verifiable text targets get an after-the-fact receipt. CGEvent posting
/// itself has no acknowledgement; without this, "events were queued" was
/// incorrectly treated as "text landed" and the transcript could vanish.
enum DeliveryVerifier {

    struct Snapshot {
        let element: AXUIElement
        let value: String?
        let range: CFRange?
    }

    /// The field's value + caret before typing (nil: neither is readable, so
    /// there is nothing to compare against).
    static func snapshot(of element: AXUIElement) -> Snapshot? {
        let value = AXRead.string(element, kAXValueAttribute as String)
        let range = AXRead.range(element, kAXSelectedTextRangeAttribute as String)
        guard value != nil || range != nil else { return nil }
        return Snapshot(element: element, value: value, range: range)
    }

    /// Re-read the field on the main thread after 80 ms, then 200 ms; call
    /// `onFailure` (main thread) only when both readings show no change.
    static func verify(_ before: Snapshot, attempt: Int = 0,
                       onFailure: @escaping () -> Void) {
        let delays: [TimeInterval] = [0.08, 0.20]
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            let afterValue = AXRead.string(before.element, kAXValueAttribute as String)
            let afterRange = AXRead.range(
                before.element, kAXSelectedTextRangeAttribute as String)
            switch receipt(beforeValue: before.value, beforeRange: before.range,
                           afterValue: afterValue, afterRange: afterRange) {
            case .landed, .unknown: return
            case .notYet: break
            }
            if attempt + 1 < delays.count {
                verify(before, attempt: attempt + 1, onFailure: onFailure)
            } else {
                Log.paste("insert delivery unconfirmed — showing copy box")
                onFailure()
            }
        }
    }

    enum Receipt: Equatable { case landed, unknown, notYet }

    /// One re-read's verdict. Pure; self-tested.
    static func receipt(beforeValue: String?, beforeRange: CFRange?,
                        afterValue: String?, afterRange: CFRange?) -> Receipt {
        // Neither could be read (a slow app past the AX timeout, or the
        // field went away): unknown — fail open like every other check,
        // rather than put up a copy box for text that was likely typed.
        if afterValue == nil && afterRange == nil { return .unknown }
        return deliveryChanged(beforeValue: beforeValue, beforeRange: beforeRange,
                               afterValue: afterValue, afterRange: afterRange) ? .landed : .notYet
    }

    /// Pure receipt rule, self-tested. Either the text value or caret/selection
    /// moving proves that the target consumed the synthetic keystrokes.
    static func deliveryChanged(beforeValue: String?, beforeRange: CFRange?,
                                afterValue: String?, afterRange: CFRange?) -> Bool {
        if let beforeValue, let afterValue, beforeValue != afterValue { return true }
        if let beforeRange, let afterRange {
            return beforeRange.location != afterRange.location
                || beforeRange.length != afterRange.length
        }
        return false
    }
}
