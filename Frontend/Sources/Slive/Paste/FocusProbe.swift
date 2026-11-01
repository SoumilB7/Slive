import AppKit
import ApplicationServices

/// Reads what has keyboard focus through Accessibility, bounded so a hung or
/// slow target app can never hold Slive's main thread. Only READS — the
/// decisions built on these facts live in `TypingPolicy`.
///
/// Thread contract: AX reads are thread-safe. `probe()` and `currentTarget()`
/// are called on the main thread (via `TypingSink`); `isStillFocused(on:)`
/// runs on the live typist's queue so it never waits behind UI work.
enum FocusProbe {

    /// What the focus probe actually learned — the three answers mean three
    /// different things and must not be conflated:
    /// - `.element`: something has focus; judge it by role.
    /// - `.none`: AX corroborated that nothing has keyboard focus. Typing
    ///   would land nowhere — show the copy box.
    /// - `.unknown`: AX couldn't answer (broken/asleep tree, Electron after
    ///   relaunch). Fail open and type; a wrong refusal here is the old bug
    ///   we removed detection over.
    enum Result {
        case element(AXUIElement)
        case none
        case unknown
    }

    enum FocusKind: Equatable {
        case text
        case nonText
        case ambiguous
    }

    // MARK: - Bounded AX

    /// Longest any one AX message may block, in seconds. The default is six,
    /// and the focus probe runs on the main thread — the thread the hotkey's
    /// consuming tap lives on — so one hung target app froze Slive and held
    /// every keystroke on the Mac behind it. A timed-out read answers
    /// `.cannotComplete`, which every check here already treats as "couldn't
    /// tell" (fail open).
    static let axTimeout: Float = 0.25
    /// Total time the focused-descendant walk may spend.
    static let descendantWalkBudget: CFAbsoluteTime = 0.3

    /// The system-wide element, timeout applied. Setting it on the
    /// system-wide element sets the process-wide default, so every element
    /// AX hands back afterwards is bounded too.
    static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, axTimeout)
        return element
    }()

    // MARK: - Probe

    static func probe() -> Result {
        let frontmost = NSWorkspace.shared.frontmostApplication
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

    static func focusedElement() -> AXUIElement? {
        if case .element(let element) = probe() { return element }
        return nil
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
    private static func corroboratedNone(frontmost app: NSRunningApplication?) -> Result {
        guard let app else { return .none }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)

        // The app-scoped query sometimes succeeds when the system-wide query
        // incorrectly returns .noValue. Prefer that concrete element.
        var appFocus: CFTypeRef?
        let appFocusError = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &appFocus)
        if appFocusError == .success, let element = AXRead.element(appFocus) {
            return resolveFocus(element, frontmost: app)
        }

        var window: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &window)
        if windowError == .noValue { return .none }
        guard windowError == .success,
              let windowElement = AXRead.element(window)
        else { return .unknown }

        // Some apps expose focus only below the window. Search a bounded slice
        // of the live tree and prefer that target over the focused window — a
        // selected text field must never be mistaken for an empty window.
        if let descendant = bestFocusedDescendant(in: windowElement) {
            return resolveCandidate(descendant, frontmost: app)
        }
        if AXRead.isFocused(windowElement) {
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

    static func appHasLazyAX(_ app: NSRunningApplication?) -> Bool {
        let electron = app?.bundleURL.map {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(
                    "Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        return isLazyAXBundle(identifier: app?.bundleIdentifier,
                              hasElectronFramework: electron)
    }

    private static func resolveFocus(_ element: AXUIElement,
                                     frontmost app: NSRunningApplication?) -> Result {
        // A container may be reported as focused even when a field deeper in
        // its tree is the actual keyboard destination. Rank the whole focused
        // slice before deciding; never let the first parent win by accident.
        if focusKind(role: AXRead.string(element, kAXRoleAttribute as String)) == .nonText,
           let descendant = bestFocusedDescendant(in: element) {
            return resolveCandidate(descendant, frontmost: app)
        }
        return resolveCandidate(element, frontmost: app)
    }

    private static func resolveCandidate(_ element: AXUIElement,
                                         frontmost app: NSRunningApplication?) -> Result {
        let role = AXRead.string(element, kAXRoleAttribute as String)
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

    /// Bounded breadth-first search used only for focused containers. It scans
    /// the whole bounded slice and ranks candidates, so a parent group cannot
    /// beat a deeper text field merely because it appeared first.
    /// Bounded by time as well as count: 256 elements are ~600 AX messages,
    /// and a slow (not hung) app answering each near the timeout would still
    /// hold the main thread for a minute.
    private static func bestFocusedDescendant(in root: AXUIElement) -> AXUIElement? {
        let deadline = CFAbsoluteTimeGetCurrent() + descendantWalkBudget
        var queue: [AXUIElement] = AXRead.children(of: root)
        var index = 0
        let limit = 256
        var best: AXUIElement?
        var bestRank = 0
        while index < queue.count && index < limit
                && CFAbsoluteTimeGetCurrent() < deadline {
            let element = queue[index]
            index += 1
            if AXRead.isFocused(element) {
                let role = AXRead.string(element, kAXRoleAttribute as String)
                let rank: Int
                switch focusKind(role: role) {
                case .text: rank = 3
                case .nonText: rank = 2
                case .ambiguous: rank = 1
                }
                if rank > bestRank { best = element; bestRank = rank }
            }
            if queue.count < limit {
                queue.append(contentsOf: AXRead.children(of: element).prefix(limit - queue.count))
            }
        }
        return best
    }

    /// True if the element is a password / secure text field, which we must
    /// never write into.
    static func isSecure(_ element: AXUIElement) -> Bool {
        // No named constant exists for the secure-field role; it's "AXSecureTextField".
        if let role = AXRead.string(element, kAXRoleAttribute as String),
           role == "AXSecureTextField" {
            return true
        }
        if let subrole = AXRead.string(element, kAXSubroleAttribute as String),
           subrole == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        return false
    }

    // MARK: - Stream target

    /// Snapshot the current focus target (call right after the stream check).
    /// nil when AX can't even name the focused app — the session then can't be
    /// guarded and types unchecked (fail open, as everywhere else here).
    static func currentTarget() -> StreamTarget? {
        guard let pid = focusedAppPID()
                ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }
        let lazy = appHasLazyAX(NSRunningApplication(processIdentifier: pid))
        return StreamTarget(pid: pid, element: lazy ? nil : rawFocusedElement())
    }

    /// Is keyboard focus still on `target` (and not on a password field)? Cheap —
    /// two to four AX reads, no tree walk. Unknown answers fail open. The
    /// machine-wide secure-input check is the caller's (`TypingSink.stillOurs`).
    static func isStillFocused(on target: StreamTarget) -> Bool {
        if let focused = rawFocusedElement() {
            if isSecure(focused) { return false }
            var pid: pid_t = 0
            if AXUIElementGetPid(focused, &pid) == .success, pid != target.pid { return false }
            if let recorded = target.element, !CFEqual(recorded, focused) { return false }
            return true
        }
        // AX couldn't name an element (asleep Electron tree): judge by app.
        if let pid = focusedAppPID() { return pid == target.pid }
        return true
    }

    /// The system-wide focused element exactly as AX reports it (no descendant
    /// resolution — identity comparisons need the same raw read both times).
    private static func rawFocusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        return err == .success ? AXRead.element(value) : nil
    }

    private static func focusedAppPID() -> pid_t? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &value)
        guard err == .success, let app = AXRead.element(value) else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(app, &pid) == .success ? pid : nil
    }
}

/// The field a live session started typing into: the focused app's PID
/// and, when its identity is trustworthy, the raw focused AX element.
/// The live typist re-checks it before each burst — focus was once checked
/// only at start, so switching apps mid-hold (or during the release→final
/// pass window) sent the corrections' BACKSPACES into the new target.
struct StreamTarget {
    let pid: pid_t
    /// nil → compare by app only: AX couldn't name the element, or the app
    /// is Chromium/Electron, whose lazily-rebuilt AX trees don't keep a
    /// stable element identity (a false mismatch would box good dictation).
    let element: AXUIElement?
}

/// Typed single-attribute AX reads. Every failure reads as nil ("couldn't
/// tell"); the messaging timeout comes from `FocusProbe.systemWide`.
enum AXRead {
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cfRange
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func isFocused(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXFocusedAttribute as CFString, &value)
        guard error == .success, let value,
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value)
        guard error == .success, let values = value as? [Any] else { return [] }
        return values.compactMap { Self.element($0 as CFTypeRef) }
    }
}
