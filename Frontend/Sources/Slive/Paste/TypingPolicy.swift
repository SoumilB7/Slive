import AppKit
import Carbon.HIToolbox
import IOKit

/// Whether Slive may type, from facts the caller gathered — pure apart from
/// the two live secure-input readers, so every rule is self-tested.
///
/// The rules are conservative, positive-only guards: refuse a password field,
/// and fall back to the copy box when focus is definitely on a non-text
/// target or on nothing. Unknown/asleep AX trees fail open, so they cannot
/// block typing into Electron (see `TypingSink` for why there is no "is this
/// a text field?" detection).
enum TypingPolicy {

    /// The focus facts the verdict needs, already read from AX.
    enum Focus: Equatable {
        /// `role` is nil when AX couldn't read it — or when the field is
        /// secure (the role is never read then).
        case element(role: String?, isSecure: Bool)
        case none
        case unknown
    }

    enum Verdict: Equatable {
        /// Type. `verifiable`: a known text role, so delivery can be checked
        /// afterwards. `failOpen`: AX couldn't tell — typing anyway.
        case type(verifiable: Bool, failOpen: Bool)
        /// Don't type. `reason` is for the log (nil: Accessibility is off,
        /// which never logged); `note` is the copy box's line (nil when the
        /// refusal is about this field only).
        case refuse(reason: String?, note: String?)

        var allowsTyping: Bool {
            if case .type = self { return true }
            return false
        }
    }

    /// The one decision behind both one-shot insert and live streaming.
    /// Lazy in the same order as ever: no secure-input read without
    /// Accessibility, no focus probe while secure input blocks.
    static func verdict(accessibility: Bool,
                        secureInput: @autoclosure () -> Bool,
                        focus: () -> Focus) -> Verdict {
        // No Accessibility permission → posted events would be dropped.
        guard accessibility else {
            return .refuse(reason: nil, note: typingBlockedNote(accessibility: false, secureInput: false))
        }
        // Secure event input is on while a password field has focus — also
        // in Chrome/Electron, whose password inputs AX may not mark secure.
        guard !secureInput() else {
            return .refuse(reason: "secure event input on",
                           note: typingBlockedNote(accessibility: true, secureInput: true))
        }
        // Never type into a password field, a positively non-text target, or
        // THE VOID. Fail-open only where AX genuinely couldn't answer — a
        // corroborated "nothing is focused" means the keystrokes would land
        // nowhere, which is exactly what the copy box is for.
        switch focus() {
        case .element(let role, let isSecure):
            if isSecure { return .refuse(reason: "secure field", note: nil) }
            if !shouldDispatch(role: role) {
                return .refuse(reason: "non-text focus (\(role ?? "unknown"))", note: nil)
            }
            return .type(verifiable: FocusProbe.focusKind(role: role) == .text, failOpen: false)
        case .none:
            return .refuse(reason: "nothing has keyboard focus", note: nil)
        case .unknown:
            return .type(verifiable: false, failOpen: true)   // AX can't tell — type anyway (Electron safety)
        }
    }

    /// The `TextSink` view of a verdict.
    static func deliverability(_ verdict: Verdict) -> Deliverability {
        switch verdict {
        case .type(_, let failOpen): return failOpen ? .unknown : .ok
        case .refuse(_, let note): return .blocked(note: note)
        }
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

    // MARK: - Secure input

    /// Secure input is on in the app we'd type into (its password field has
    /// focus). macOS reports secure input machine-wide, and Terminal's Secure
    /// Keyboard Entry or a password manager can leave it on for hours, so
    /// the app holding it is matched against the frontmost one. When the
    /// holder can't be read, any secure input counts.
    static func secureInputBlocksTyping() -> Bool {
        guard IsSecureEventInputEnabled() else { return false }
        return secureInputBlocks(enabled: true, owner: secureInputOwnerPID(),
                                 frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// Pure owner-vs-frontmost rule, self-tested.
    static func secureInputBlocks(enabled: Bool, owner: pid_t?, frontmost: pid_t?) -> Bool {
        guard enabled else { return false }
        guard let owner else { return true }
        return owner == frontmost
    }

    /// The process that turned secure input on (the window server records it
    /// on the console user's registry entry).
    private static func secureInputOwnerPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let users = value as? [[String: Any]] else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 { return pid_t(pid) }
        }
        return nil
    }

    // MARK: - Copy-box note

    /// Why typing is blocked outright, in a few words for the copy box —
    /// the machine-wide reasons a user can act on. nil when typing was
    /// possible, or refused for this field only.
    static var typingBlockedNote: String? {
        typingBlockedNote(accessibility: AXIsProcessTrusted(),
                          secureInput: secureInputBlocksTyping())
    }

    /// Pure copy rule, self-tested.
    static func typingBlockedNote(accessibility: Bool, secureInput: Bool) -> String? {
        if !accessibility { return "Not typed · Accessibility is off" }
        if secureInput { return "Not typed · secure input is on" }
        return nil
    }
}
