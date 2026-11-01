import CoreGraphics
import Foundation

/// Posts synthetic keystrokes — the same trust model as the user's own
/// keyboard. No focus checks here: callers decide (`TypingPolicy`) and guard
/// (`StreamTarget`) before posting. Safe from any thread.
enum SyntheticTyper {

    /// Tag written onto every synthetic keystroke Slive posts (via the event's
    /// `eventSourceUserData` field). The hotkey monitor uses it to ignore our own
    /// typing so live dictation — which types WHILE the stream key is held —
    /// doesn't look like the key was released.
    static let syntheticMarker: Int64 = 0x5_11E_71DE   // "slive type"

    /// Serialises every one-shot type-out (see `enqueue`).
    private static let typingQueue = DispatchQueue(label: "com.slive.app.pastetyping",
                                                   qos: .userInitiated)

    /// Type `text` asynchronously, then run `then` on the same queue.
    ///
    /// Type it out with synthetic key events. We deliberately do NOT use the
    /// AX insert (kAXSelectedText): Electron/Monaco (VS Code, the Claude Code
    /// extension) falsely reports `.success` without actually inserting.
    /// Synthetic typing IS keyboard input, so it lands reliably everywhere —
    /// native fields, browsers, Electron, terminals. Async so pacing never
    /// blocks the UI — on ONE serial queue: two quick inserts on the old
    /// concurrent global queue could interleave their keystrokes.
    static func enqueue(_ text: String, then: @escaping () -> Void = {}) {
        typingQueue.async {
            typeOut(text)
            then()
        }
    }

    /// Type `text` into the frontmost app via synthetic Unicode key events.
    /// Works anywhere a keyboard works — Electron, VS Code, terminals — because
    /// it *is* keyboard input, not a paste, and it never touches the clipboard.
    /// Slive's overlay is non-activating, so the user's app stays frontmost and
    /// receives the keystrokes. One event carries a whole run of characters, so
    /// this posts ≤20-unit chunks rather than one event per character — long
    /// transcripts land almost instantly. (Was 24 *Characters* per event, which
    /// overran the per-event limit and apps silently dropped the excess.)
    private static func typeOut(_ text: String) {
        postUnicode(text)
    }

    /// Post a run of characters as synthetic keystrokes (tagged + modifier-
    /// cleared so our hotkey tap ignores them and a held stream key can't alter
    /// them), split by `unicodeChunks` — many apps silently truncate a unicode
    /// string longer than ~20 UTF-16 units, so one long post lost text while the
    /// caller believed it was typed. No focus check here — the live typist
    /// re-checks its `StreamTarget` before each burst and serialises calls on
    /// its own queue.
    static func postUnicode(_ s: String) {
        guard !s.isEmpty, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for (i, chunk) in unicodeChunks(s).enumerated() {
            if i > 0 { usleep(800) }   // brief pacing between chunks (keeps fast apps from dropping input)
            postUnicodeEvent(chunk, source: source)
        }
    }

    /// Most UTF-16 units one unicode key event may carry. 20 is CGEvent's
    /// documented ceiling; past it apps truncate the string.
    static let maxUnicodeUnitsPerEvent = 20

    /// Split `s` into runs of ≤ `maxUnits` UTF-16 units, never splitting a
    /// grapheme cluster (half an emoji or a base without its combining mark
    /// types as garbage). A single cluster longer than the limit (a long ZWJ
    /// emoji sequence) goes alone in its own event. Pure; self-tested.
    static func unicodeChunks(_ s: String, maxUnits: Int = maxUnicodeUnitsPerEvent) -> [String] {
        var chunks: [String] = []
        var current = ""
        var units = 0
        for ch in s {
            let n = ch.utf16.count
            if units > 0 && units + n > maxUnits {
                chunks.append(current)
                current = ""; units = 0
            }
            current.append(ch); units += n
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// One key-down/up pair carrying `chunk` (already ≤ the per-event limit).
    private static func postUnicodeEvent(_ chunk: String, source: CGEventSource) {
        let utf16 = Array(chunk.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: buffer.count,
                                              unicodeString: buffer.baseAddress)
                // Strip modifiers so a held stream key (e.g. ⌥) can't turn the
                // typed character into an accented glyph or a shortcut, and tag
                // it so our own hotkey tap ignores it.
                down.flags = []
                down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: buffer.count,
                                            unicodeString: buffer.baseAddress)
                up.flags = []
                up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Post one backspace (Delete) keypress — used to correct the still-forming
    /// tail as the recogniser revises it.
    static func postBackspace() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let deleteKey: CGKeyCode = 0x33   // Delete / Backspace
        if let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true) {
            down.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false) {
            up.flags = []
            up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            up.post(tap: .cghidEventTap)
        }
    }
}
