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
        // THE VOID. Fail-open only where AX genuinely couldn't answer — a
        // corroborated "nothing is focused" means the keystrokes would land
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
    /// - `.none`: AX corroborated that nothing has keyboard focus. Typing
    ///   would land nowhere — show the copy box.
    /// - `.unknown`: AX couldn't answer (broken/asleep tree, Electron after
    ///   relaunch). Fail open and type; a wrong refusal here is the old bug
    ///   we removed detection over.
    enum FocusProbe {
        case element(AXUIElement)
        case none
        case unknown
    }

    enum FocusKind: Equatable {
        case text
        case nonText
        case ambiguous
    }

    static func probeFocus() -> FocusProbe {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        switch err {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return corroboratedNone(frontmost: frontmost)
            }
            return resolveFocus((value as! AXUIElement), frontmost: frontmost)
        default:
            return Self.axSaysNothingFocused(err)
                ? corroboratedNone(frontmost: frontmost) : .unknown
        }
    }

    /// Pure decision, self-tested: which AX errors CLAIM nothing is focused
    /// (needing corroboration) vs plainly "couldn't tell" (fail open).
    static func axSaysNothingFocused(_ error: AXError) -> Bool {
        error == .noValue
    }

    /// `.noValue` from the system-wide probe is AMBIGUOUS, learned the hard
    /// way: a desktop/no-caret window answers it — but so does a Chromium/
    /// Electron app whose lazy AX tree hasn't registered its focused element
    /// while a real field has focus. Corroborate the void in either of the two
    /// cases macOS can prove: the app has no focused window, or the focused
    /// window itself is the positive focused target after checking its
    /// descendants for a real field. An unreadable/asleep window remains
    /// `.unknown` and fails open for Electron.
    private static func corroboratedNone(frontmost app: NSRunningApplication?) -> FocusProbe {
        guard let app else { return .none }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // The app-scoped query sometimes succeeds when the system-wide query
        // incorrectly returns .noValue. Prefer that concrete element.
        var appFocus: CFTypeRef?
        let appFocusError = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &appFocus)
        if appFocusError == .success, let element = axElement(appFocus) {
            return resolveFocus(element, frontmost: app)
        }

        var window: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &window)
        if windowError == .noValue { return .none }
        guard windowError == .success,
              let windowElement = axElement(window)
        else { return .unknown }

        // Some apps expose focus only below the window. Search a bounded slice
        // of the live tree and prefer that target over the focused window — a
        // selected text field must never be mistaken for an empty window.
        if let descendant = bestFocusedDescendant(in: windowElement) {
            return resolveCandidate(descendant, frontmost: app)
        }
        if isFocused(windowElement) {
            return resolveCandidate(windowElement, frontmost: app)
        }
        return .unknown
    }

    /// Pure first-stage rule, self-tested. Only a positively missing focused
    /// window proves the void by itself; a live window needs element-level
    /// inspection because it may contain the selected text field.
    static func confirmsNoFocus(windowError: AXError) -> Bool {
        windowError == .noValue
    }

    /// Role-only part of focus resolution, kept pure for regression tests.
    /// Containers are not text merely because they are focused; their
    /// descendants must produce a real text/cell target first.
    static func focusKind(role: String?) -> FocusKind {
        switch role {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
             kAXCellRole, kAXRowRole, kAXTableRole, kAXOutlineRole,
             kAXListRole, kAXBrowserRole:
            return .text
        case kAXWindowRole, kAXApplicationRole, kAXGroupRole,
             kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
             kAXSliderRole, kAXMenuItemRole, kAXImageRole,
             kAXStaticTextRole, kAXScrollAreaRole, kAXToolbarRole,
             kAXPopUpButtonRole, "AXLink", "AXWebArea":
            return .nonText
        default:
            return .ambiguous
        }
    }

    /// Electron/Chromium may expose only a focused group while its real text
    /// field is absent from the lazy AX tree. Preserve fail-open only for that
    /// known class instead of treating every native focused group as typable.
    static func isLazyAXBundle(identifier: String?, hasElectronFramework: Bool) -> Bool {
        if hasElectronFramework { return true }
        let id = (identifier ?? "").lowercased()
        return id.contains("chrome") || id.contains("chromium")
            || id.contains("brave") || id.contains("edgemac")
            || id.contains("arc")
    }

    private static func appHasLazyAX(_ app: NSRunningApplication?) -> Bool {
        let electron = app?.bundleURL.map {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(
                    "Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        return isLazyAXBundle(identifier: app?.bundleIdentifier,
                              hasElectronFramework: electron)
    }

    private static func resolveFocus(_ element: AXUIElement,
                                     frontmost app: NSRunningApplication?) -> FocusProbe {
        // A container may be reported as focused even when a field deeper in
        // its tree is the actual keyboard destination. Rank the whole focused
        // slice before deciding; never let the first parent win by accident.
        if focusKind(role: stringAttribute(element, kAXRoleAttribute as String)) == .nonText,
           let descendant = bestFocusedDescendant(in: element) {
            return resolveCandidate(descendant, frontmost: app)
        }
        return resolveCandidate(element, frontmost: app)
    }

    private static func resolveCandidate(_ element: AXUIElement,
                                         frontmost app: NSRunningApplication?) -> FocusProbe {
        let role = stringAttribute(element, kAXRoleAttribute as String)
        switch focusKind(role: role) {
        case .text:
            return .element(element)
        case .nonText:
            // Known controls can use shouldDispatch for the final refusal.
            // Groups are special: native groups mean no text target, while a
            // lazy Electron group is genuinely ambiguous and must fail open.
            if role == (kAXGroupRole as String) {
                return appHasLazyAX(app) ? .unknown : .none
            }
            return .element(element)
        case .ambiguous:
            return appHasLazyAX(app) ? .unknown : .none
        }
    }

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func isFocused(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXFocusedAttribute as CFString, &value)
        guard error == .success, let value,
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    /// Bounded breadth-first search used only for focused containers. It scans
    /// the whole bounded slice and ranks candidates, so a parent group cannot
    /// beat a deeper text field merely because it appeared first.
    private static func bestFocusedDescendant(in root: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = children(of: root)
        var index = 0
        let limit = 256
        var best: AXUIElement?
        var bestRank = 0
        while index < queue.count && index < limit {
            let element = queue[index]
            index += 1
            if isFocused(element) {
                let role = stringAttribute(element, kAXRoleAttribute as String)
                let rank: Int
                switch focusKind(role: role) {
                case .text: rank = 3
                case .nonText: rank = 2
                case .ambiguous: rank = 1
                }
                if rank > bestRank { best = element; bestRank = rank }
            }
            if queue.count < limit {
                queue.append(contentsOf: children(of: element).prefix(limit - queue.count))
            }
        }
        return best
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value)
        guard error == .success, let values = value as? [Any] else { return [] }
        return values.compactMap { axElement($0 as CFTypeRef) }
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
             // Only roles where typing NEVER enters text. Deliberately NOT:
             // AXGroup (half-built Electron trees report groups while a real
             // field has focus) and NOT cell/row/table/outline/list/browser —
             // spreadsheet-pattern apps (Numbers, Excel) begin CELL EDITING
             // on a keystroke to a focused cell, so refusing those would box
             // legitimate dictation. Scroll areas (desktop icon view),
             // toolbars, popups and links only ever type-select.
             kAXScrollAreaRole,
             kAXToolbarRole,
             kAXPopUpButtonRole,
             "AXLink",
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
