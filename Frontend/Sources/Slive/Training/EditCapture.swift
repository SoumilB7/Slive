import AppKit
import ApplicationServices

/// Captures a training data point per dictation-into-a-field:
///
///  1. Just before Slive types, snapshot the field's text + caret and remember
///     short **anchors** of the text on either side of the insertion point
///     (`capturePre`).
///  2. Slive types its transcript in.
///  3. Finalize — read the field's final text, isolate the section between the
///     anchors, and store (transcript → section) plus audio — when the edit
///     focus **leaves that section**. Two triggers, whichever comes first:
///       - **boundary crossed** (primary): the caret moves outside the section.
///         Moving on to a different sentence/paragraph means you're done editing
///         Slive's output — you either accepted it or finished changing it. This
///         works even when the field never loses focus (chat inputs, editors).
///       - **focus-off** (backstop): the field loses focus / is destroyed / the
///         app deactivates — for the cases the boundary signal can't see.
///
/// Only the section that was Slive's output (as edited) is stored, never the
/// whole field. All offsets are UTF-16 (matching AX ranges) so caret comparisons
/// and anchor slicing agree.
@MainActor
final class EditCapture {
    static let shared = EditCapture()

    /// Pre-insertion snapshot: the field and the context anchors around the caret.
    struct Pre {
        let element: AXUIElement
        let leftAnchor: String
        let rightAnchor: String
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
        let startedAt: Date
    }

    /// How much surrounding text to remember as a matching anchor.
    private static let anchorLen = 24
    /// Ignore boundary checks for a beat after begin, while Slive's own typing
    /// lands (so our keystrokes can't be mistaken for the user moving on).
    private static let settleDelay: TimeInterval = 0.5

    private var observer: AXObserver?
    private var deactivateObserver: NSObjectProtocol?
    private var pending: Pending?

    // MARK: - Public flow

    /// Snapshot the focused editable field's caret context BEFORE Slive types.
    /// Returns nil when there's no readable, non-secure editable field (so the
    /// copy-box path and password fields are never captured).
    func capturePre() -> Pre? {
        // Classification is PasteEngine's — deliberately the SAME gate that
        // decides whether we type at all. Keeping a second copy here meant the
        // two could disagree (they did: capture refused Electron fields that
        // typed fine), so typing and capture must always agree by construction.
        guard AXIsProcessTrusted(), let focused = Self.focusedElement() else { return nil }
        guard !PasteEngine.isSecure(focused), let el = PasteEngine.editableTarget(focused) else {
            Log.training("capturePre skipped — not an editable text context")
            return nil
        }
        let ns = (Self.stringValue(el) ?? "") as NSString
        let caret = min(Self.caretOffset(el) ?? ns.length, ns.length)
        let leftStart = max(0, caret - Self.anchorLen)
        let left = ns.substring(with: NSRange(location: leftStart, length: caret - leftStart))
        let rightLen = min(Self.anchorLen, ns.length - caret)
        let right = ns.substring(with: NSRange(location: caret, length: rightLen))
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return Pre(element: el, leftAnchor: left, rightAnchor: right, app: app)
    }

    /// Begin tracking after Slive has started typing `transcript`. Copies the
    /// audio now (the source wav is deleted soon) and installs the watchers.
    func begin(pre: Pre, transcript: String, audioURL: URL?) {
        finalizeIfPending(reason: "superseded")   // close any earlier capture first

        let id = UUID().uuidString
        let audioFile = audioURL.flatMap { TrainingStore.shared.ingestAudio($0, id: id) }
        pending = Pending(id: id, element: pre.element, transcript: transcript,
                          audioFile: audioFile, leftAnchor: pre.leftAnchor,
                          rightAnchor: pre.rightAnchor, app: pre.app, startedAt: Date())
        installObservers(on: pre.element)
        Log.training("begin — «\(String(transcript.suffix(40)))»  left=«\(String(pre.leftAnchor.suffix(10)))» right=«\(String(pre.rightAnchor.prefix(10)))»")
    }

    // MARK: - Observation

    private func installObservers(on element: AXUIElement) {
        teardownObservers()

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let capture = Unmanaged<EditCapture>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in capture.handleAXEvent() }
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appEl = AXUIElementCreateApplication(pid)
        // Caret / content changes drive the boundary check; focus / destroy are
        // the backstops.
        AXObserverAddNotification(obs, element, kAXSelectedTextChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, element, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, element, kAXUIElementDestroyedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs

        // Backstop: whole app losing focus is also a focus-off for our field.
        deactivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.finalizeIfPending(reason: "app-deactivate") }
        }
    }

    /// Fired on any observed AX change. Finalize if focus left the field, or if
    /// the caret has moved outside the tracked section.
    private func handleAXEvent() {
        guard let p = pending else { return }

        // Backstop: focus left our element entirely.
        let current = Self.focusedElement()
        if current == nil || !CFEqual(current!, p.element) {
            finalizeIfPending(reason: "focus-off"); return
        }

        // Primary: caret moved past the section boundary → done editing it.
        // Skip during the settle window so Slive's own typing isn't read as the
        // user moving on.
        guard Date().timeIntervalSince(p.startedAt) >= Self.settleDelay else { return }
        guard let caret = Self.caretOffset(p.element),
              let value = Self.stringValue(p.element),
              let (start, end) = Self.bounds(value, p.leftAnchor, p.rightAnchor) else { return }
        if caret < start || caret > end {
            finalizeIfPending(reason: "boundary")
        }
    }

    // MARK: - Finalize

    private func finalizeIfPending(reason: String) {
        guard let p = pending else { return }
        pending = nil
        teardownObservers()

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

    private func teardownObservers() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observer = nil
        }
        if let d = deactivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(d)
            deactivateObserver = nil
        }
    }

    // MARK: - Section location / partitioning (all UTF-16 offsets)

    /// UTF-16 offsets [start, end) of the section between the anchors, or nil if
    /// an anchor can't be found (field edited beyond the section).
    static func bounds(_ value: String, _ left: String, _ right: String) -> (Int, Int)? {
        let ns = value as NSString
        var start = 0
        if !left.isEmpty {
            let r = ns.range(of: left)
            if r.location == NSNotFound { return nil }
            start = r.location + r.length
        }
        var end = ns.length
        if !right.isEmpty {
            let searchRange = NSRange(location: start, length: ns.length - start)
            let r = ns.range(of: right, options: [], range: searchRange)
            if r.location == NSNotFound { return nil }
            end = r.location
        }
        guard end >= start else { return nil }
        return (start, end)
    }

    /// Isolate the section between the anchors in the final text. The only thing
    /// kept: "what Slive's insertion turned into."
    static func partition(final: String?, left: String, right: String) -> (String?, String) {
        guard let final, let (start, end) = bounds(final, left, right) else {
            return (nil, "unresolved")
        }
        let section = (final as NSString).substring(with: NSRange(location: start, length: end - start))
        let confidence = (left.isEmpty && right.isEmpty) ? "low" : "high"
        return (section, confidence)
    }

    // MARK: - AX helpers

    /// Shared with PasteEngine so focus + classification can never diverge.
    private static func focusedElement() -> AXUIElement? { PasteEngine.focusedElement() }

    private static func stringValue(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return (v as! CFString) as String
    }

    /// Caret as a UTF-16 offset (end of the selection).
    private static func caretOffset(_ el: AXUIElement) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &range) else { return nil }
        return range.location + range.length
    }

}
