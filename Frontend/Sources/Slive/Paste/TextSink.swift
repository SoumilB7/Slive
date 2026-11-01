import Foundation

/// Where finished text goes. `TypingSink` types it at the caret;
/// `ClipboardSink` hands it to the copy box (auto-insert off).
///
/// Adding a destination = one type conforming to `TextSink` (and
/// `LiveTextSink` if it can follow a live transcript), selected where the
/// dictation result is delivered.
protocol TextSink {
    /// Could text be delivered right now? Safe from any thread.
    func canDeliver() -> Deliverability
    /// Deliver `text`. True when it was dispatched; false means the caller
    /// shows the copy box. `onDeliveryFailure` fires (main thread) if a
    /// dispatch is later found not to have landed.
    func deliver(_ text: String, onDeliveryFailure: @escaping () -> Void) -> Bool
}

extension TextSink {
    func deliver(_ text: String) -> Bool { deliver(text, onDeliveryFailure: {}) }
}

enum Deliverability: Equatable {
    /// A field that takes text is focused.
    case ok
    /// Not now. `note` is the copy box's line when the user can act on it
    /// (Accessibility off, secure input); nil for this-field-only refusals
    /// or when the user turned typing off.
    case blocked(note: String?)
    /// AX couldn't tell — delivery goes ahead (fail open for Electron).
    case unknown

    var allowsDelivery: Bool {
        if case .blocked = self { return false }
        return true
    }
}

/// A destination that follows a live transcript with corrections, driven by
/// `LiveTypist`. Called on the typist's queue except `beginStream`.
protocol LiveTextSink {
    /// Claim the current destination for one live session (main thread).
    func beginStream() -> LiveStreamHandle
    /// Delete `backspaces` characters before the caret, then insert `insert`.
    func replace(backspaces: Int, insert: String)
    /// Is the destination still the one `handle` claimed? False stops typing
    /// for the rest of the session (the text goes to the copy box instead).
    func stillOurs(_ handle: LiveStreamHandle) -> Bool
}

/// One live session's claim on a destination.
struct LiveStreamHandle {
    /// Whether anything may be typed this session at all.
    let allowed: Bool
    /// What `stillOurs` re-checks; nil = unguarded (types unchecked — fail open).
    let target: StreamTarget?
}
