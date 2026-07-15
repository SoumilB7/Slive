import AppKit
import ApplicationServices

/// Captures a training data point per dictation-into-a-field:
///
///  1. Just before Slive types, snapshot the field's text + cursor position
///     (`capturePre`). We remember short **anchors** of the text on either side
///     of the insertion point.
///  2. Slive types its transcript in.
///  3. When that field loses focus — the single stop signal — read its final
///     text, locate the section between the anchors, and store
///     (transcript → final section) plus the audio.
///
/// Only the section that was Slive's output (as edited by the user) is stored,
/// never the whole field. Focus-off is detected via an `AXObserver` on the app's
/// focused-element-changed notification (plus app-deactivation as a backstop).
@MainActor
final class EditCapture {
    static let shared = EditCapture()

    /// Pre-insertion snapshot of the target field.
    struct Pre {
        let element: AXUIElement
        let beforeValue: String
        let insertionIndex: Int
        let app: String?
    }

    private struct Pending {
        let id: String
        let element: AXUIElement
        let transcript: String
        let audioFile: String?
        let leftAnchor: String
        let rightAnchor: String
        let app: String?
    }

    /// How much surrounding text to remember as a matching anchor.
    private static let anchorLen = 24

    private var observer: AXObserver?
    private var deactivateObserver: NSObjectProtocol?
    private var pending: Pending?

    // MARK: - Public flow

    /// Read the focused editable field's text + caret BEFORE Slive types. Returns
    /// nil when there's no readable, non-secure editable field (so nothing is
    /// captured for the copy-box path or password fields).
    func capturePre() -> Pre? {
        guard AXIsProcessTrusted(), let el = Self.focusedElement() else { return nil }
        guard !Self.isSecure(el), Self.isEditable(el) else { return nil }
        let value = Self.stringValue(el) ?? ""
        let idx = min(Self.caretIndex(el) ?? value.count, value.count)
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return Pre(element: el, beforeValue: value, insertionIndex: idx, app: app)
    }

    /// Begin tracking after Slive has started typing `transcript` into the field
    /// described by `pre`. Copies the audio now (the source wav is deleted soon)
    /// and installs the focus-off watcher.
    func begin(pre: Pre, transcript: String, audioURL: URL?) {
        finalizeIfPending(reason: "superseded")   // close any earlier capture first

        let id = UUID().uuidString
        let chars = Array(pre.beforeValue)
        let i = max(0, min(pre.insertionIndex, chars.count))
        let left = String(chars[max(0, i - Self.anchorLen)..<i])
        let right = String(chars[i..<min(chars.count, i + Self.anchorLen)])
        let audioFile = audioURL.flatMap { TrainingStore.shared.ingestAudio($0, id: id) }

        pending = Pending(id: id, element: pre.element, transcript: transcript,
                          audioFile: audioFile, leftAnchor: left, rightAnchor: right, app: pre.app)
        installFocusObserver(on: pre.element)
        Log.training("begin — «\(String(transcript.suffix(40)))»  left=«\(String(left.suffix(10)))» right=«\(String(right.prefix(10)))»")
    }

    // MARK: - Focus-off detection

    private func installFocusObserver(on element: AXUIElement) {
        teardownObserver()

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let capture = Unmanaged<EditCapture>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in capture.focusMaybeChanged() }
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appEl = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, element, kAXUIElementDestroyedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs

        // Backstop: the whole app losing focus is also a focus-off for our field
        // (and some apps don't post focused-element-changed on the way out).
        deactivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.focusMaybeChanged() }
        }
    }

    private func focusMaybeChanged() {
        guard let pending else { return }
        let current = Self.focusedElement()
        if current == nil || !CFEqual(current!, pending.element) {
            finalizeIfPending(reason: "focus-off")
        }
    }

    // MARK: - Finalize

    private func finalizeIfPending(reason: String) {
        guard let p = pending else { return }
        pending = nil
        teardownObserver()

        let finalValue = Self.stringValue(p.element)
        let (section, confidence) = Self.partition(final: finalValue,
                                                   left: p.leftAnchor, right: p.rightAnchor)
        let resolved = section ?? ""
        let edited = section != nil && section != p.transcript
        let sample = EditSample(
            id: p.id, createdAt: Date(), app: p.app,
            transcript: p.transcript, finalText: resolved,
            edited: edited, confidence: confidence, audioFile: p.audioFile)
        TrainingStore.shared.add(sample)

        Log.training("""
        finalize (\(reason)) edited=\(edited) conf=\(confidence)
          slive: «\(p.transcript)»
          final: «\(section ?? "<unreadable>")»
        """)
    }

    private func teardownObserver() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observer = nil
        }
        if let d = deactivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(d)
            deactivateObserver = nil
        }
    }

    // MARK: - Partitioning

    /// Isolate the section between the two context anchors in the final text.
    /// This is the only thing kept: "what Slive's insertion turned into."
    static func partition(final: String?, left: String, right: String) -> (String?, String) {
        guard let final else { return (nil, "unresolved") }

        // Locate the left anchor (start of the section = just after it).
        var startOffset = 0
        if !left.isEmpty {
            guard let r = final.range(of: left) else { return (nil, "unresolved") }
            startOffset = final.distance(from: final.startIndex, to: r.upperBound)
        }
        let startIdx = final.index(final.startIndex, offsetBy: startOffset)

        // Locate the right anchor at/after the start (end of the section).
        var endIdx = final.endIndex
        if !right.isEmpty {
            guard let r = final.range(of: right, range: startIdx..<final.endIndex) else {
                return (nil, "unresolved")
            }
            endIdx = r.lowerBound
        }
        guard startIdx <= endIdx else { return (nil, "unresolved") }

        let section = String(final[startIdx..<endIdx])
        let confidence = (left.isEmpty && right.isEmpty) ? "low" : "high"
        return (section, confidence)
    }

    // MARK: - AX helpers

    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringValue(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return (v as! CFString) as String
    }

    /// Caret position as a character offset (UTF-16-based AX range; good enough
    /// for anchor extraction on ordinary BMP text).
    private static func caretIndex(_ el: AXUIElement) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &range) else { return nil }
        return range.location + range.length   // end of selection = caret
    }

    private static func isSecure(_ el: AXUIElement) -> Bool {
        if roleString(el, kAXRoleAttribute) == "AXSecureTextField" { return true }
        if roleString(el, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return true }
        return false
    }

    private static func isEditable(_ el: AXUIElement) -> Bool {
        let role = roleString(el, kAXRoleAttribute)
        if role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue, stringValue(el) != nil {
            return true
        }
        return false
    }

    private static func roleString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return (v as! CFString) as String
    }
}
