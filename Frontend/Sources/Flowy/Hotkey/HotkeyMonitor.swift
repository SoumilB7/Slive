import AppKit

/// Global hold-to-talk monitor. Fires `onStart` when the fn (🌐) key goes down
/// and `onStop` when it comes back up — anywhere in the system, whatever app
/// is focused.
///
/// On a `flagsChanged` event the `.function` flag tracks the physical fn key:
/// arrow keys and F-keys emit `keyDown` events, not `flagsChanged`, so they
/// never trip this monitor. (Heads-up: if System Settings ▸ Keyboard has
/// "Press 🌐 key to" set to Start Dictation, macOS may also react — we only
/// observe, never consume, the key.)
final class HotkeyMonitor {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    func start() {
        // Global: events while another app is focused (the normal case).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
        }
        // Local: events if Flowy itself somehow has focus. Must return the event.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let fnDown = event.modifierFlags.contains(.function)
        if fnDown && !isDown {
            isDown = true
            onStart?()
        } else if !fnDown && isDown {
            isDown = false
            onStop?()
        }
    }

    // MARK: - Permissions

    /// Whether the app is trusted for Accessibility (required for global
    /// keyboard monitoring). Pass `prompt: true` to surface the system dialog.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
