import AppKit
import CoreGraphics
import IOKit.hid

/// Global hold-to-talk monitor for the fn (🌐) key.
///
/// Uses a `CGEventTap` rather than an `NSEvent` monitor: the tap reliably
/// reports the fn key via `CGEventFlags.maskSecondaryFn`, where plain NSEvent
/// global monitors can miss it. We listen to `flagsChanged` only, so arrow /
/// F-keys (which emit `keyDown`) never trip it.
///
/// The tap needs Accessibility permission. If it isn't granted yet, we poll
/// and install automatically the moment you enable it — no relaunch required.
final class HotkeyMonitor {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    /// Which key acts as push-to-talk. Change it live from Settings.
    var choice: HotkeyChoice = Settings.shared.hotkey {
        didSet {
            // If we swap keys mid-hold, don't leave a dangling recording.
            if isDown { isDown = false; onStop?() }
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?
    private var isDown = false

    func start() {
        // A keyboard CGEventTap is gated by *Input Monitoring*, not Accessibility.
        // Requesting it surfaces the system prompt the first time.
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSLog("Flowy: Input Monitoring granted = \(granted); Accessibility = \(AXIsProcessTrusted())")

        installTap()   // the tap object exists even before the grant

        if !granted {
            NSLog("Flowy: waiting for Input Monitoring — enable Flowy in Settings, no relaunch needed.")
            startPolling()
        }
    }

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil; runLoopSource = nil
    }

    // MARK: - Tap installation

    @discardableResult
    private func installTap() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: refcon
        ) else {
            return false
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = src
        NSLog("Flowy: ✅ event tap installed — hold fn to talk.")
        return true
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if HotkeyMonitor.inputMonitoringGranted {
                NSLog("Flowy: Input Monitoring granted — re-arming tap.")
                self.reinstallTap()
                timer.invalidate()
                self.pollTimer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// Re-create the tap after a permission change so events start flowing
    /// without needing an app relaunch.
    private func reinstallTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        installTap()
    }

    // MARK: - Event handling

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        // macOS disables a tap that's slow or after certain input; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Only react to the physical key the user chose.
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == choice.keycode else { return }

        let down = event.flags.contains(choice.mask)
        if down && !isDown {
            isDown = true
            onStart?()
        } else if !down && isDown {
            isDown = false
            onStop?()
        }
    }

    // MARK: - Permissions

    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// C-compatible tap callback: recover the monitor from `refcon` and forward.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
