import AppKit
import CoreGraphics
import IOKit.hid

/// Global hold-to-talk monitor for a user-recorded shortcut (`Hotkey`).
///
/// - A **modifier-only** shortcut uses a listen-only tap (Input Monitoring).
/// - A **chord with a key** uses a consuming tap (Accessibility) so the key is
///   swallowed while held instead of typing into the focused app.
///
/// Only the EXACT recorded key + modifiers is ever consumed — every other event
/// passes straight through, so a bug here can't swallow unrelated keystrokes.
final class HotkeyMonitor {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    /// The recorded shortcut. Change it live from Settings; the tap re-arms if
    /// its listen/consume mode needs to change.
    var hotkey: Hotkey = Settings.shared.hotkey {
        didSet {
            if isActive { isActive = false; mainKeyEngaged = false; onStop?() }
            if oldValue.isModifierOnly != hotkey.isModifierOnly {
                reinstallTap()   // listen ↔ consume mode changed
            }
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?
    private var healthTimer: Timer?

    private var isActive = false          // the combo is currently held
    private var mainKeyEngaged = false    // we consumed the chord key's key-down
    private var hasReceivedEvent = false

    // MARK: - Lifecycle

    func start() {
        // Ask for both permissions up front so either shortcut style works:
        // modifier-only needs Input Monitoring, a chord needs Accessibility.
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        _ = Self.ensureAccessibility(prompt: false)
        NSLog("Flowy: InputMonitoring=\(Self.inputMonitoringGranted) Accessibility=\(AXIsProcessTrusted())")

        installTap()
        if !tapGranted { startPolling() }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        healthTimer?.invalidate(); healthTimer = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil; runLoopSource = nil
    }

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Whether the permission the CURRENT shortcut's tap needs is granted.
    private var tapGranted: Bool {
        hotkey.isModifierOnly ? Self.inputMonitoringGranted : AXIsProcessTrusted()
    }

    // MARK: - Tap

    @discardableResult
    private func installTap() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        )
        // Consuming tap for chords (so we can swallow the key), listen-only for
        // modifier-only shortcuts (nothing to suppress).
        let option: CGEventTapOptions = hotkey.isModifierOnly ? .listenOnly : .defaultTap
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: option,
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
        startHealthCheck()
        NSLog("Flowy: ✅ hotkey tap installed (\(option == .listenOnly ? "listen" : "consume")).")
        return true
    }

    private func reinstallTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil; runLoopSource = nil
        installTap()
        if !tapGranted { startPolling() }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.tapGranted {
                NSLog("Flowy: permission granted — re-arming hotkey tap.")
                self.reinstallTap()
                timer.invalidate(); self.pollTimer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func startHealthCheck() {
        healthTimer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        healthTimer = t
    }

    private func markActive() {
        guard !hasReceivedEvent else { return }
        hasReceivedEvent = true
        DispatchQueue.main.async { Settings.shared.hotkeyActive = true }
    }

    // MARK: - Event handling  (returns true to CONSUME the event)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        markActive()

        let flags = event.flags.rawValue & Hotkey.modifierMask

        // Modifier-only shortcut: active when exactly those modifiers are held.
        if hotkey.isModifierOnly {
            setActive(held: flags == hotkey.modifiers && hotkey.modifiers != 0)
            return false   // never consume
        }

        // Chord with a key.
        let keycode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            if keycode == hotkey.keyCode && flags == hotkey.modifiers {
                mainKeyEngaged = true
                if !isActive { isActive = true; onStart?() }
                return true    // swallow (incl. autorepeat) so it never types
            }
        case .keyUp:
            if keycode == hotkey.keyCode && mainKeyEngaged {
                mainKeyEngaged = false
                if isActive { isActive = false; onStop?() }
                return true    // swallow the matching key-up too
            }
        case .flagsChanged:
            // Released a required modifier while active → stop. The key may still
            // be physically down; its key-up is still swallowed via mainKeyEngaged.
            if isActive && flags != hotkey.modifiers {
                isActive = false
                onStop?()
            }
        default:
            break
        }
        return false
    }

    private func setActive(held: Bool) {
        if held && !isActive { isActive = true; onStart?() }
        else if !held && isActive { isActive = false; onStop?() }
    }

    // MARK: - Permissions

    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}

/// C-compatible tap callback: recover the monitor, forward the event, and pass
/// or swallow it based on the monitor's decision.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
