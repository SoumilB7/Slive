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

    /// Tag written onto every synthetic keystroke Slive posts (via the event's
    /// `eventSourceUserData` field). The hotkey monitor uses it to ignore our own
    /// typing so live dictation — which types WHILE the stream key is held —
    /// doesn't look like the key was released.
    static let syntheticMarker: Int64 = 0x5_11E_71DE   // "slive type"

    /// Whether we may stream-type right now: Accessibility granted and the focused
    /// element is an editable, non-secure text field. Checked once at the start of
    /// a live dictation session (focus is stable while you hold the key). Safe to
    /// call from any thread — it hops to the main thread for the AX calls.
    static func canStreamType() -> Bool {
        func check() -> Bool {
            guard AXIsProcessTrusted(), let element = focusedElement() else { return false }
            guard !isSecure(element) else { return false }
            if editableTarget(element) != nil { return true }
            Log.paste("stream refused — \(describe(element))")
            return false
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
        // contexts, where characters could trigger shortcuts). If it doesn't look
        // like one, the app's AX tree may simply be asleep (common right after a
        // relaunch) — wake it and re-read focus once before giving up.
        guard editableTarget(element) != nil else {
            Log.paste("insert refused — \(describe(element))")
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

    // MARK: - Focus discovery

    /// Resolve `element` to an editable text target, waking the owning app's AX
    /// tree and re-reading focus once if it doesn't look editable at first.
    /// Returns nil only if it genuinely isn't a text-editing context.
    static func editableTarget(_ element: AXUIElement) -> AXUIElement? {
        if isEditableTextField(element) { return element }
        // Nothing usable — the tree may be asleep (relaunched Electron/Chromium).
        guard wakeAXTree(of: element) else { return nil }
        guard let refreshed = focusedElement(), !isSecure(refreshed),
              isEditableTextField(refreshed) else { return nil }
        Log.paste("AX tree was asleep — recovered after wake")
        return refreshed
    }

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

    /// True if the element looks like an editable text field or text area.
    ///
    /// Deliberately broader than "AX says I can set its value": we insert with
    /// synthetic keystrokes, not the AX value (see `typeOut`), so a field that
    /// refuses `AXValue` writes still types perfectly. Gating on settability
    /// therefore rejected fields that work fine — Electron/Chromium and
    /// contentEditable surfaces in particular. What we actually need to know is
    /// "is this a text-editing context", and the reliable tell for that is a
    /// caret: only text contexts expose `AXSelectedTextRange`. Buttons, sliders
    /// and steppers don't, so this stays safe from typing into a non-text
    /// context where characters would fire shortcuts.
    private static func isEditableTextField(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as String)
        if role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String) {
            return true
        }

        // A caret/selection means it's a text-editing context.
        if hasAttribute(element, kAXSelectedTextRangeAttribute as String) { return true }

        // Last resort: a settable string value.
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

    private static func hasAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            && value != nil
    }

    /// Apps that were relaunched (⌘Q → reopen) can come back with their
    /// accessibility tree switched OFF: Chromium/Electron build it lazily, only
    /// once an assistive client asks. Until then the focused element reports
    /// almost nothing — no usable role, no caret — so we'd wrongly conclude "not
    /// a text field" and fall back to the copy box, even though the keyboard
    /// types into it fine (the app's own input path has nothing to do with AX).
    ///
    /// `AXManualAccessibility` is Electron's documented opt-in to build the tree
    /// on demand. Set once per pid, then the caller re-reads focus.
    ///
    /// (We deliberately do NOT set `AXEnhancedUserInterface` — it's the VoiceOver
    /// flag, and some apps respond to it by mangling their window layout.)
    private static var axWokenPids = Set<pid_t>()

    private static func wakeAXTree(of element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        guard !axWokenPids.contains(pid) else { return false }
        axWokenPids.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Log.paste("woke AX tree for pid \(pid)")
        return true
    }

    /// Why an insert was refused — only built when verbose logging is on.
    private static func describe(_ element: AXUIElement) -> String {
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? "nil"
        let sub = stringAttribute(element, kAXSubroleAttribute as String) ?? "nil"
        let caret = hasAttribute(element, kAXSelectedTextRangeAttribute as String)
        var settable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        return "app=\(app) role=\(role) subrole=\(sub) caret=\(caret) settable=\(settable.boolValue)"
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
