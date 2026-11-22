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

    /// Re-read the field on the main thread after 80, 200, then 600 ms;
    /// call `onFailure` (main thread) unless one reading confirms the text.
    static func verify(_ before: Snapshot, attempt: Int = 0,
                       onFailure: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            let afterValue = AXRead.string(before.element, kAXValueAttribute as String)
            let afterRange = AXRead.range(
                before.element, kAXSelectedTextRangeAttribute as String)
            let seen = receipt(beforeValue: before.value, beforeRange: before.range,
                               afterValue: afterValue, afterRange: afterRange)
            switch step(seen, attempt: attempt) {
            case .done: return
            case .retry: verify(before, attempt: attempt + 1, onFailure: onFailure)
            case .fail:
                Log.paste("insert delivery unconfirmed\(seen == .unknown ? " (field unreadable)" : "") — showing copy box")
                onFailure()
            }
        }
    }

    /// When each re-read happens. The last look is late for apps that report
    /// their text slowly (Ghostty, Nov 26: typed, still unchanged at 0.28 s).
    /// The box only ever comes after a miss, so waiting costs nothing when
    /// it landed.
    static let delays: [TimeInterval] = [0.08, 0.20, 0.60]

    enum Receipt: Equatable { case landed, unknown, notYet }

    enum Step: Equatable { case retry, done, fail }

    /// What one re-read means. Pure; self-tested. Only `.landed` ends it
    /// quietly: the copy box shows unless the text is CONFIRMED, so an
    /// unreadable field counts as a miss, not a pass.
    static func step(_ receipt: Receipt, attempt: Int, attempts: Int = delays.count) -> Step {
        if receipt == .landed { return .done }
        return attempt + 1 < attempts ? .retry : .fail
    }

    /// One re-read's verdict. Pure; self-tested.
    static func receipt(beforeValue: String?, beforeRange: CFRange?,
                        afterValue: String?, afterRange: CFRange?) -> Receipt {
        // Neither could be read (a slow app past the AX timeout, or the
        // field went away): nothing proves the text landed.
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
