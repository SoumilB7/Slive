import AppKit
import ApplicationServices

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
/// The one AX read kept is the secure-field guard, and it FAILS OPEN: it only
/// refuses when the focused element positively identifies as a password field
/// (`AXSecureTextField`). An unreadable or asleep AX tree can never block typing.
enum PasteEngine {

    /// Tag written onto every synthetic keystroke Slive posts (via the event's
    /// `eventSourceUserData` field). The hotkey monitor uses it to ignore our own
    /// typing so live dictation — which types WHILE the stream key is held —
    /// doesn't look like the key was released.
    static let syntheticMarker: Int64 = 0x5_11E_71DE   // "slive type"

    /// Whether we may stream-type right now: Accessibility granted (needed to
    /// post events at all) and the focused element is not a password field.
    /// Checked once at the start of a live dictation session. Safe to call from
    /// any thread — it hops to the main thread for the AX read.
    static func canStreamType() -> Bool {
        func check() -> Bool {
            guard AXIsProcessTrusted() else { return false }
            if let element = focusedElement(), isSecure(element) {
                Log.paste("stream refused — secure field")
                return false
            }
            return true
        }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
    }

    /// Post one run of characters as a single synthetic keystroke (tagged +
    /// modifier-cleared so our hotkey tap ignores it and a held stream key can't
    /// alter it). The live typist calls this one character at a time for a smooth
    /// reveal. No focus check here — the caller gates the session with
    /// `canStreamType()` and serialises calls on its own queue.
    static func postUnicode(_ s: String) {
        guard !s.isEmpty, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let utf16 = Array(s.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                down.flags = []
                down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
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

    /// Type `text` at the caret, wherever it is.
    ///
    /// - Returns: `true` when typing was dispatched; `false` only for empty
    ///   text, missing Accessibility permission (events would be discarded), or
    ///   a positively-identified password field.
    static func insertIfPossible(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        // The AX read and event posting belong on the main thread.
        if Thread.isMainThread {
            return performInsert(text)
        }
        return DispatchQueue.main.sync { performInsert(text) }
    }

    // MARK: - Core

    private static func performInsert(_ text: String) -> Bool {
        // No Accessibility permission → posted events would be dropped.
        guard AXIsProcessTrusted() else { return false }

        // Never type into a password field. Fail-open by design: refuse only on
        // a positive identification, so a broken AX tree can't block typing.
        if let element = focusedElement(), isSecure(element) {
            Log.paste("insert refused — secure field")
            return false
        }

        // Type it out with synthetic key events. We deliberately do NOT use the
        // AX insert (kAXSelectedText): Electron/Monaco (VS Code, the Claude Code
        // extension) falsely reports `.success` without actually inserting.
        // Synthetic typing IS keyboard input, so it lands reliably everywhere —
        // native fields, browsers, Electron, terminals. Async so pacing never
        // blocks the UI.
        DispatchQueue.global(qos: .userInitiated).async { typeOut(text) }
        return true
    }

    // MARK: - Focus

    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        // Confirm we actually got an AXUIElement before force-casting.
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    /// True if the element is a password / secure text field, which we must
    /// never write into.
    static func isSecure(_ element: AXUIElement) -> Bool {
        // No named constant exists for the secure-field role; it's "AXSecureTextField".
        if let role = stringAttribute(element, kAXRoleAttribute as String),
           role == "AXSecureTextField" {
            return true
        }
        if let subrole = stringAttribute(element, kAXSubroleAttribute as String),
           subrole == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        return false
    }

    // MARK: - Insertion: type it out

    /// Type `text` into the frontmost app one character at a time via synthetic
    /// Unicode key events. Works anywhere a keyboard works — Electron, VS Code,
    /// terminals — because it *is* keyboard input, not a paste, and it never
    /// touches the clipboard. Slive's overlay is non-activating, so the user's
    /// app stays frontmost and receives the keystrokes.
    private static func typeOut(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // A single key event can carry a whole run of characters, so type in
        // small chunks instead of one event per character — far fewer events,
        // so long transcripts land almost instantly. A short pause between
        // chunks keeps fast apps from dropping input.
        let chars = Array(text)
        let chunkSize = 12
        var i = 0
        while i < chars.count {
            let chunk = String(chars[i..<min(i + chunkSize, chars.count)])
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
            i += chunkSize
            usleep(1200)   // brief pacing between chunks
        }
    }
}
