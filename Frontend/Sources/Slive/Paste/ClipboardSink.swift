import Foundation

/// Copy-only: nothing is typed, the text goes to the copy box (whose button
/// puts it on the clipboard). What auto-insert off means. Delivery never
/// touches the clipboard by itself — that has always been the user's click.
struct ClipboardSink: TextSink, LiveTextSink {
    /// Blocked by choice — no note: the user turned typing off themselves.
    func canDeliver() -> Deliverability { .blocked(note: nil) }

    func deliver(_ text: String, onDeliveryFailure: @escaping () -> Void) -> Bool { false }

    func beginStream() -> LiveStreamHandle { LiveStreamHandle(allowed: false, target: nil) }

    func replace(backspaces: Int, insert: String) {}

    func stillOurs(_ handle: LiveStreamHandle) -> Bool { false }
}
