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
        let trusted = AXIsProcessTrusted()
        diag("insertIfPossible len=\(text.count) AXTrusted=\(trusted)")
        // No Accessibility permission → we can't read focus or post events.
        guard trusted else { return false }

        // Something must have keyboard focus, else we'd paste into nowhere — let
        // the caller fall back to the copy box instead.
        guard let element = focusedElement() else { diag("no focused element"); return false }

        let role = stringAttribute(element, kAXRoleAttribute as String) ?? "?"
        let subrole = stringAttribute(element, kAXSubroleAttribute as String) ?? "-"
        diag("focused role=\(role) subrole=\(subrole)")

        // Never insert into a secure/password field.
        guard !isSecure(element) else { diag("secure field → skip"); return false }

        // Strategy 1: clean AX insert when the field exposes an editable text
        // role (native fields, most web inputs) — no clipboard involved.
        if isEditableTextField(element), setSelectedText(element, text) {
            diag("strategy 1: AX insert OK")
            return true
        }

        // Strategy 2: type it out with synthetic key events — the universal
        // path. Reaches Electron / VS Code / terminal editors (Monaco, the
        // Claude Code extension) that ignore ⌘V and expose no settable AX value,
        // because this *is* keyboard input, not a paste. Runs async so the
        // per-character pacing never blocks the UI.
        diag("strategy 2: typing \(text.count) chars")
        DispatchQueue.global(qos: .userInitiated).async { typeOut(text) }
        return true
    }

    /// Append a diagnostic line to /tmp/flowy-paste.log (temporary, for debugging).
    private static func diag(_ msg: String) {
        NSLog("Flowy paste: \(msg)")
        let line = "\(msg)\n"
        let url = URL(fileURLWithPath: "/tmp/flowy-paste.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
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

    // MARK: - Strategy 1: AX insert

    /// Replace the current selection (or insert at the caret) via
    /// `kAXSelectedTextAttribute`. Returns true on `.success`.
    private static func setSelectedText(_ element: AXUIElement, _ text: String) -> Bool {
        let err = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString)
        return err == .success
    }

    // MARK: - Strategy 2: type it out

    /// Type `text` into the frontmost app one character at a time via synthetic
    /// Unicode key events. Works anywhere a keyboard works — Electron, VS Code,
    /// terminals — because it *is* keyboard input, not a paste, and it never
    /// touches the clipboard. Flowy's overlay is non-activating, so the user's
    /// app stays frontmost and receives the keystrokes.
    private static func typeOut(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            diag("typeOut: no CGEventSource"); return
        }
        diag("typeOut: posting \(text.count) chars")
        for character in text {
            let utf16 = Array(String(character).utf16)
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
            usleep(1200)   // ~1.2ms pacing so fast apps don't drop characters
        }
    }
}
