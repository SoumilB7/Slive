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
/// The AX reads kept are conservative, positive-only guards: refuse a password
/// field, and fall back to the copy box when focus is definitely on a
/// non-editable target. Unknown/asleep AX trees still fail open, so they cannot
/// block typing into Electron.
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
            switch probeFocus() {
            case .element(let element):
                if isSecure(element) {
                    Log.paste("stream refused — secure field")
                    return false
                }
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if !shouldDispatch(role: role) {
                    Log.paste("stream refused — non-text focus (\(role ?? "unknown"))")
                    return false
                }
                return true
            case .none:
                Log.paste("stream refused — nothing has keyboard focus")
                return false
            case .unknown:
                return true   // AX can't tell — stream anyway (Electron safety)
            }
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
    /// - Returns: `true` when typing was dispatched; `false` for empty text,
    ///   missing Accessibility permission, a positively-identified password
    ///   field, or a positively-identified non-text target. Unknown/broken AX
    ///   trees still fail open so Electron fields are never falsely refused.
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

        // Never type into a password field, a positively non-text target, or
        // THE VOID. Fail-open only where AX genuinely couldn't answer — an
        // authoritative "nothing is focused" means the keystrokes would land
        // nowhere, which is exactly what the copy box is for.
        switch probeFocus() {
        case .element(let element):
            if isSecure(element) {
                Log.paste("insert refused — secure field")
                return false
            }
            let role = stringAttribute(element, kAXRoleAttribute as String)
            if !shouldDispatch(role: role) {
                Log.paste("insert refused — non-text focus (\(role ?? "unknown"))")
                return false
            }
        case .none:
            Log.paste("insert refused — nothing has keyboard focus")
            return false
        case .unknown:
            break   // AX can't tell — type anyway (Electron safety)
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

    /// What the focus probe actually learned — the three answers mean three
    /// different things and must not be conflated:
    /// - `.element`: something has focus; judge it by role.
    /// - `.none`: AX answered AUTHORITATIVELY that nothing has keyboard focus
    ///   (`.noValue`). Typing would land nowhere — show the copy box.
    /// - `.unknown`: AX couldn't answer (broken/asleep tree, Electron after
    ///   relaunch). Fail open and type; a wrong refusal here is the old bug
    ///   we removed detection over.
    enum FocusProbe {
        case element(AXUIElement)
        case none
        case unknown
    }

    static func probeFocus() -> FocusProbe {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        switch err {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return corroboratedNone()
            }
            return .element((value as! AXUIElement))
        default:
            return Self.axSaysNothingFocused(err) ? corroboratedNone() : .unknown
        }
    }

    /// Pure decision, self-tested: which AX errors CLAIM nothing is focused
    /// (needing corroboration) vs plainly "couldn't tell" (fail open).
    static func axSaysNothingFocused(_ error: AXError) -> Bool {
        error == .noValue
    }

    /// `.noValue` from the system-wide probe is AMBIGUOUS, learned the hard
    /// way: a desktop with no window answers it — but so does a Chromium/
    /// Electron app whose lazy AX tree hasn't registered its focused element
    /// while a real field has focus (the regression that made dictation only
    /// ever offer the copy box). So the void must be CORROBORATED: only when
    /// the frontmost app also positively reports "no focused window" do we
    /// believe nothing is focused. A live window, or an unreadable app,
    /// fails open and types.
    private static func corroboratedNone() -> FocusProbe {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .none }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &window)
        return Self.confirmsNoFocus(windowError: err) ? .none : .unknown
    }

    /// Pure corroboration rule, self-tested: only the app's own authoritative
    /// "no focused window" (.noValue) confirms the void.
    static func confirmsNoFocus(windowError: AXError) -> Bool {
        windowError == .noValue
    }

    static func focusedElement() -> AXUIElement? {
        if case .element(let element) = probeFocus() { return element }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    /// Decide whether keyboard text should be dispatched from the AX facts we
    /// can trust. Known text roles type; a small set of unambiguously non-text
    /// roles shows the copy box. Everything else remains unknown and fails open
    /// for Electron/webview fields whose AX trees are absent or incomplete.
    static func shouldDispatch(role: String?) -> Bool {
        switch role {
        case kAXTextFieldRole,
             kAXTextAreaRole,
             kAXComboBoxRole:
            return true
        case kAXWindowRole,
             kAXApplicationRole,
             kAXButtonRole,
             kAXCheckBoxRole,
             kAXRadioButtonRole,
             kAXSliderRole,
             kAXMenuItemRole,
             kAXImageRole,
             kAXStaticTextRole,
             // Containers focus actually rests on when no field is selected —
             // Finder list/column views, icon grids, sidebars, toolbars. A
             // focused CONTAINER is not a caret; keystrokes there only
             // trigger type-select. (Deliberately NOT AXGroup: half-built
             // Electron trees report groups while a real field has focus.)
             kAXScrollAreaRole,
             kAXOutlineRole,
             kAXTableRole,
             kAXListRole,
             kAXBrowserRole,
             kAXToolbarRole,
             kAXPopUpButtonRole,
             "AXLink",
             kAXRowRole,
             kAXCellRole,
             "AXWebArea":
            return false
        default:
            return true
        }
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
        let chunkSize = 24   // was 12: half the events + half the pacing sleeps
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
            usleep(800)    // brief pacing between chunks (keeps fast apps from dropping input)
        }
    }
}
