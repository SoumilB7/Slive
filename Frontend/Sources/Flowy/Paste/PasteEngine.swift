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

        // Something must have keyboard focus, else we'd paste into nowhere — let
        // the caller fall back to the copy box instead.
        guard let element = focusedElement() else { return false }

        // Never insert into a secure/password field.
        guard !isSecure(element) else { return false }

        // Strategy 1: clean AX insert when the field exposes an editable text
        // role (native fields, most web inputs) — no clipboard involved.
        if isEditableTextField(element), setSelectedText(element, text) {
            return true
        }

        // Strategy 2: ⌘V fallback. This is what reaches Electron / VS Code /
        // terminal editors (e.g. the Claude Code extension's Monaco view) whose
        // custom text areas don't expose a settable AX value. Something is
        // focused and it isn't secure, so the paste lands in the right place.
        return pasteViaClipboard(text)
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

    // MARK: - Strategy 2: clipboard paste fallback

    /// Save the clipboard, put our text on it, synthesize ⌘V into the frontmost
    /// app, then restore the clipboard after a short delay so the paste lands.
    private static func pasteViaClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard postCommandV() else {
            // Couldn't post the paste — restore immediately and bail.
            restoreClipboard(saved)
            return false
        }

        // Give the frontmost app time to consume ⌘V before we restore.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            restoreClipboard(saved)
        }
        return true
    }

    private static func restoreClipboard(_ saved: String?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let saved {
            pasteboard.setString(saved, forType: .string)
        }
    }

    /// Synthesize ⌘V via CGEvent (keycode 9 = 'v'), posted to the HID tap so it
    /// reaches whatever app is frontmost. Flowy's overlay is non-activating, so
    /// the user's app stays frontmost and receives the paste.
    private static func postCommandV() -> Bool {
        let vKeyCode: CGKeyCode = 9  // kVK_ANSI_V
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        guard
            let keyDown = CGEvent(
                keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(
                keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
