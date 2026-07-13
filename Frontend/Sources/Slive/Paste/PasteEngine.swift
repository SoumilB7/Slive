import AppKit
import ApplicationServices

/// Inserts a transcript directly into the focused, editable text field of the
/// frontmost app — so the user never has to paste by hand.
///
/// Everything here is gated by *Accessibility* permission (`AXIsProcessTrusted`),
/// not entitlements. It is deliberately defensive: any failure returns `false`
/// so the caller can fall back to showing the copy box, and it never touches a
/// secure/password field.
enum PasteEngine {

    /// Try to insert `text` at the cursor of the focused editable field.
    ///
    /// - Returns: `true` only if the text was actually inserted; `false`
    ///   otherwise (empty text, no permission, no editable field, secure field,
    ///   or both insert strategies failed).
    static func insertIfPossible(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        // AX and event posting must happen on the main thread.
        if Thread.isMainThread {
            return performInsert(text)
        }
        return DispatchQueue.main.sync { performInsert(text) }
    }

    // MARK: - Core

    private static func performInsert(_ text: String) -> Bool {
        // No Accessibility permission → we can't read focus or post events.
        guard AXIsProcessTrusted() else { return false }

        // Something must have keyboard focus, else we'd type into nowhere — let
        // the caller fall back to the copy box instead.
        guard let element = focusedElement() else { return false }

        // Never insert into a secure/password field.
        guard !isSecure(element) else { return false }

        // Must be a focused editable text field (avoid typing into non-text
        // contexts, where characters could trigger shortcuts).
        guard isEditableTextField(element) else { return false }

        // Type it out with synthetic key events. We deliberately do NOT use the
        // AX insert (kAXSelectedText): Electron/Monaco (VS Code, the Claude Code
        // extension) falsely reports `.success` without actually inserting.
        // Synthetic typing IS keyboard input, so it lands reliably everywhere —
        // native fields, browsers, Electron, terminals. Async so pacing never
        // blocks the UI.
        DispatchQueue.global(qos: .userInitiated).async { typeOut(text) }
        return true
    }

    // MARK: - Focus discovery

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        // Confirm we actually got an AXUIElement before force-casting.
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: - Field classification

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    /// True if the element is a password / secure text field, which we must
    /// never write into.
    private static func isSecure(_ element: AXUIElement) -> Bool {
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

    /// True if the element looks like an editable text field or text area.
    /// Accepts either a matching role, or a settable `AXValue` (covers web /
    /// Electron fields whose role doesn't map cleanly).
    private static func isEditableTextField(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as String)
        if role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) {
            return true
        }

        // Fall back to "is the value settable" — but only for things that at
        // least expose a text value, to avoid targeting sliders/steppers etc.
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable)
        if err == .success, settable.boolValue {
            // Require the value to be a string, so we don't hit numeric controls.
            var value: CFTypeRef?
            let vErr = AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &value)
            if vErr == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() {
                return true
            }
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
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: buffer.count,
                                                unicodeString: buffer.baseAddress)
                    up.post(tap: .cghidEventTap)
                }
            }
            i += chunkSize
            usleep(1200)   // brief pacing between chunks
        }
    }
}
