import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

/// Dictation fallback / copy box
@MainActor
enum PasteFocusTests {
    static let suite = TestSuite(name: "Paste focus") { t in
        print("[Paste focus]")
        t.check(PasteEngine.shouldDispatch(role: kAXTextFieldRole as String),
              "text field receives dictation")
        t.check(PasteEngine.shouldDispatch(role: kAXTextAreaRole as String),
              "text area receives dictation")
        t.check(PasteEngine.focusKind(role: kAXTextFieldRole as String) == .text
                && PasteEngine.focusKind(role: kAXCellRole as String) == .text,
              "focus resolver ranks fields and editable cells as text")
        t.check(PasteEngine.focusKind(role: kAXWindowRole as String) == .nonText
                && PasteEngine.focusKind(role: kAXGroupRole as String) == .nonText,
              "focus resolver never mistakes native containers for text")
        t.check(PasteEngine.focusKind(role: "AXUnknownElectronRole") == .ambiguous,
              "unknown focus remains explicitly ambiguous")
        t.check(PasteEngine.isLazyAXBundle(identifier: "com.google.Chrome",
                                         hasElectronFramework: false)
                && PasteEngine.isLazyAXBundle(identifier: "anything",
                                              hasElectronFramework: true)
                && !PasteEngine.isLazyAXBundle(identifier: "com.apple.TextEdit",
                                               hasElectronFramework: false),
              "only Chromium/Electron gets ambiguous-focus fail-open")
        let start = CFRange(location: 4, length: 0)
        t.check(PasteEngine.deliveryChanged(beforeValue: "hello", beforeRange: start,
                                          afterValue: "hello world",
                                          afterRange: CFRange(location: 11, length: 0)),
              "changed text/caret confirms synthetic delivery")
        t.check(!PasteEngine.deliveryChanged(beforeValue: "hello", beforeRange: start,
                                           afterValue: "hello", afterRange: start),
              "unchanged verifiable target triggers copy-box fallback")
        t.check(PasteEngine.shouldDispatch(role: "AXUnknownElectronRole"),
              "unknown Electron role fails open")
        t.check(PasteEngine.shouldDispatch(role: kAXGroupRole as String),
              "unclassified group fails open")
        t.check(!PasteEngine.shouldDispatch(role: kAXWindowRole as String),
              "window focus falls back to copy box")
        t.check(!PasteEngine.shouldDispatch(role: kAXButtonRole as String),
              "button focus falls back to copy box")
        t.check(!PasteEngine.shouldDispatch(role: kAXStaticTextRole as String),
              "static text focus falls back to copy box")
        t.check(!PasteEngine.shouldDispatch(role: "AXWebArea"),
              "ordinary web page focus falls back to copy box")
        // Never-text containers (desktop icon view, toolbars, popups) are
        // copy-box…
        for role in [kAXScrollAreaRole, kAXToolbarRole, kAXPopUpButtonRole] {
            t.check(!PasteEngine.shouldDispatch(role: role as String),
                  "never-text container (\(role)) falls back to copy box")
        }
        // …but cell/table/outline focus TYPES: spreadsheet apps begin cell
        // editing on a keystroke — boxing those broke real dictation.
        for role in [kAXCellRole, kAXRowRole, kAXTableRole, kAXOutlineRole,
                     kAXListRole, kAXBrowserRole] {
            t.check(PasteEngine.shouldDispatch(role: role as String),
                  "cell/list focus (\(role)) still types (cell-edit-on-keystroke)")
        }
        // AX's answers about focus map to distinct verdicts — and a claimed
        // "nothing focused" (.noValue) is only a CLAIM: sleeping Electron
        // trees answer it while a real field has focus, so it must be
        // corroborated by the frontmost app before the copy box wins.
        t.check(PasteEngine.axSaysNothingFocused(.noValue),
              "AX .noValue claims nothing focused (first stage)")
        t.check(!PasteEngine.axSaysNothingFocused(.cannotComplete)
                && !PasteEngine.axSaysNothingFocused(.apiDisabled)
                && !PasteEngine.axSaysNothingFocused(.notImplemented),
              "AX can't-answer errors fail open and type")
        t.check(PasteEngine.confirmsNoFocus(windowError: .noValue),
              "app confirming 'no focused window' corroborates the void → copy box")
        // The copy box says why only for machine-wide blocks the user can fix.
        t.check(PasteEngine.typingBlockedNote(accessibility: true, secureInput: false) == nil,
              "typing possible → copy box carries no note")
        t.check(PasteEngine.typingBlockedNote(accessibility: false, secureInput: false)?
                .contains("Accessibility") == true,
              "no Accessibility → copy box says so")
        t.check(PasteEngine.typingBlockedNote(accessibility: true, secureInput: true)?
                .contains("secure input") == true,
              "secure input on → copy box says so")
        // A hung app can't hold the main thread (and the hotkey tap) for long.
        t.check(PasteEngine.axTimeout > 0 && PasteEngine.axTimeout <= 0.5
                && PasteEngine.descendantWalkBudget <= 0.5,
              "AX reads and the focus walk are time-bounded")
        t.check(!PasteEngine.confirmsNoFocus(windowError: .success)
                && !PasteEngine.confirmsNoFocus(windowError: .cannotComplete)
                && !PasteEngine.confirmsNoFocus(windowError: .apiDisabled),
              "a live or unreadable window needs element-level inspection")
    }
}
