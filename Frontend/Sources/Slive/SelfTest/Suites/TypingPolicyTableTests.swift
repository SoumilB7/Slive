import ApplicationServices
import SliveTestKit

/// Whether Slive types, for every combination of the things the user
/// controls or the Mac reports: Accessibility on/off × secure input (off,
/// held by the app we'd type into, by another app, holder unreadable —
/// which blocks only over a password field) ×
/// what has focus (fields, password fields, cells, controls, Electron and
/// Chromium trees, nothing, AX silent). The expected column is the rule
/// table in TypingPolicy's docs, written out — not re-derived from the code.
@MainActor
enum TypingPolicyTableTests {
    enum Outcome: Equatable, CustomStringConvertible {
        case typeVerified, typeFailOpen
        case refuseAccessibility, refuseSecureInput, refuseSecureField, refuseNonText, refuseNothing

        var description: String {
            switch self {
            case .typeVerified: return "types (checked)"
            case .typeFailOpen: return "types (fail-open)"
            case .refuseAccessibility: return "copy box: Accessibility"
            case .refuseSecureInput: return "copy box: secure input"
            case .refuseSecureField: return "copy box: password field"
            case .refuseNonText: return "copy box: not a text target"
            case .refuseNothing: return "copy box: nothing focused"
            }
        }
    }

    /// What has focus, as AX describes it.
    struct Situation {
        let name: String
        /// nil: the probe itself answered (AX silent → .unknown, no window → .none).
        let role: String?
        let probe: TypingPolicy.Focus?
        let secure: Bool
        let app: String?
        let electron: Bool
        /// The rule table, once nothing machine-wide blocks.
        let expect: Outcome
    }

    static let chromiumIDs = ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
                              "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
                              "company.thebrowser.dia", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
    static let electronIDs = ["com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.hnc.Discord",
                              "notion.id", "md.obsidian"]
    static let nativeIDs = ["com.apple.TextEdit", "com.apple.Safari", "com.apple.Notes", "com.apple.mail",
                            "com.apple.dt.Xcode", "com.apple.Terminal", "com.apple.iWork.Numbers"]

    static var situations: [Situation] {
        func s(_ name: String, role: String?, secure: Bool = false, app: String? = "com.apple.TextEdit",
               electron: Bool = false, _ expect: Outcome) -> Situation {
            Situation(name: name, role: role, probe: nil, secure: secure, app: app, electron: electron, expect: expect)
        }
        var list: [Situation] = [
            s("text field", role: kAXTextFieldRole, .typeVerified),
            s("text area", role: kAXTextAreaRole, .typeVerified),
            s("combo box", role: kAXComboBoxRole, .typeVerified),
            s("spreadsheet cell", role: kAXCellRole, app: "com.apple.iWork.Numbers", .typeVerified),
            s("table / outline / list", role: kAXOutlineRole, app: "com.apple.finder", .typeVerified),
            s("password field", role: kAXTextFieldRole, secure: true, .refuseSecureField),
            s("password field (secure role)", role: "AXSecureTextField", secure: true, .refuseSecureField),
            s("Electron password field (secure role)", role: "AXSecureTextField", secure: true,
              app: "com.tinyspeck.slackmacgap", electron: true, .refuseSecureField),
            s("button", role: kAXButtonRole, .refuseNonText),
            s("web area", role: "AXWebArea", app: "com.apple.Safari", .refuseNonText),
            s("link", role: "AXLink", app: "com.apple.Safari", .refuseNonText),
            s("static text", role: kAXStaticTextRole, .refuseNonText),
            s("window", role: kAXWindowRole, .refuseNonText),
            s("native group", role: kAXGroupRole, app: "com.apple.Notes", .refuseNothing),
            s("native unknown role", role: "AXSomethingNew", app: "com.apple.Notes", .refuseNothing),
            s("unreadable role, native", role: nil, .refuseNothing),
            Situation(name: "AX can't answer", role: nil, probe: .unknown, secure: false, app: nil, electron: false,
                      expect: .typeFailOpen),
            Situation(name: "no window (corroborated)", role: nil, probe: TypingPolicy.Focus.none, secure: false,
                      app: "com.apple.finder", electron: false, expect: .refuseNothing),
        ]
        for id in electronIDs {
            list.append(s("Electron field (\(id))", role: kAXTextFieldRole, app: id, electron: true, .typeVerified))
            list.append(s("Electron lazy group (\(id))", role: kAXGroupRole, app: id, electron: true, .typeFailOpen))
            list.append(s("Electron unknown role (\(id))", role: "AXUnknown", app: id, electron: true, .typeFailOpen))
        }
        for id in chromiumIDs {
            list.append(s("Chromium lazy group (\(id))", role: kAXGroupRole, app: id, .typeFailOpen))
            list.append(s("Chromium unknown role (\(id))", role: nil, app: id, .typeFailOpen))
        }
        return list
    }

    /// The probe's answer for a situation, the way TypingSink builds it.
    static func focus(_ s: Situation) -> TypingPolicy.Focus {
        if let probe = s.probe { return probe }
        let lazy = { FocusProbe.isLazyAXBundle(identifier: s.app, hasElectronFramework: s.electron) }
        switch FocusProbe.candidate(role: s.role, lazyAX: lazy) {
        case .element: return .element(role: s.secure ? nil : s.role, isSecure: s.secure)
        case .none: return .none
        case .unknown: return .unknown
        }
    }

    static func outcome(_ v: TypingPolicy.Verdict) -> Outcome? {
        switch v {
        case .type(verifiable: true, failOpen: false): return .typeVerified
        case .type(verifiable: false, failOpen: true): return .typeFailOpen
        case .type: return nil   // no rule produces this
        case .refuse(.none, .some(let note)) where note.contains("Accessibility"): return .refuseAccessibility
        case .refuse(.some, .some(let note)) where note.contains("secure input"): return .refuseSecureInput
        case .refuse(.some("secure field"), .none): return .refuseSecureField
        case .refuse(.some(let r), .none) where r.hasPrefix("non-text focus"): return .refuseNonText
        case .refuse(.some("nothing has keyboard focus"), .none): return .refuseNothing
        default: return nil
        }
    }

    /// Secure input as the Mac reports it, and whether it blocks typing here
    /// (nil: only over a password field).
    static let secureInputStates: [(name: String, enabled: Bool, owner: pid_t?, frontmost: pid_t?, blocks: Bool?)] = [
        ("off", false, nil, 100, false),
        ("held by the app we'd type into", true, 100, 100, true),
        ("held by another app (Terminal, a password manager)", true, 200, 100, false),
        ("on, holder unreadable", true, nil, 100, nil),
        ("held by an app, no frontmost app", true, 200, nil, false),
    ]

    static let suite = TestSuite(name: "Typing policy table") { t in
        print("[Typing policy table]")
        var table = Sweep(), lazyRead = Sweep(), delivery = Sweep()
        var rows = 0
        for accessibility in [false, true] {
            for secure in secureInputStates {
                for situation in situations {
                    rows += 1
                    var readSecure = false, probed = false
                    let blocks = TypingPolicy.secureInputBlocks(enabled: secure.enabled, owner: secure.owner,
                                                                frontmost: secure.frontmost,
                                                                focusIsSecure: situation.secure)
                    let wantBlocks = secure.blocks ?? situation.secure
                    let verdict = TypingPolicy.verdict(
                        accessibility: accessibility,
                        secureInput: { readSecure = true; return blocks }(),
                        focus: { probed = true; return focus(situation) })
                    let want: Outcome = !accessibility ? .refuseAccessibility
                        : wantBlocks ? .refuseSecureInput : situation.expect
                    table.expect(blocks == wantBlocks && outcome(verdict) == want,
                                 "AX \(accessibility), secure input \(secure.name), \(situation.name): "
                                 + "\(outcome(verdict).map(String.init(describing:)) ?? "\(verdict)") ≠ \(want)")
                    // Nothing is read that the verdict doesn't need.
                    lazyRead.expect(readSecure == accessibility && probed == (accessibility && !wantBlocks),
                                    "AX \(accessibility), \(secure.name), \(situation.name)")
                    let d = TypingPolicy.deliverability(verdict)
                    let wantDelivery: Deliverability
                    switch verdict {
                    case .type(_, let failOpen): wantDelivery = failOpen ? .unknown : .ok
                    case .refuse(_, let note): wantDelivery = .blocked(note: note)
                    }
                    delivery.expect(d == wantDelivery && verdict.allowsTyping == (want == .typeVerified || want == .typeFailOpen),
                                    "\(situation.name): \(d)")
                }
            }
        }
        table.report(&t, "every Accessibility × secure input × focus row gets its documented verdict (\(rows) rows)")
        lazyRead.report(&t, "secure input is read only with Accessibility; focus only when nothing machine-wide blocks")
        delivery.report(&t, "each verdict maps to its delivery: checked, unknown (fail-open) or blocked with the note")

        // Which apps get Electron's fail-open for a half-built AX tree.
        var lazy = Sweep()
        for id in chromiumIDs { lazy.expect(FocusProbe.isLazyAXBundle(identifier: id, hasElectronFramework: false), id) }
        for id in electronIDs { lazy.expect(FocusProbe.isLazyAXBundle(identifier: id, hasElectronFramework: true), id) }
        for id in nativeIDs + [""] {
            lazy.expect(!FocusProbe.isLazyAXBundle(identifier: id, hasElectronFramework: false), "native \(id)")
        }
        lazy.expect(!FocusProbe.isLazyAXBundle(identifier: nil, hasElectronFramework: false), "unknown app")
        lazy.report(&t, "Chromium browsers (Arc, Dia, Vivaldi, Opera too) and Electron apps fail open; native apps don't")
    }
}
