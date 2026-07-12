import AppKit
import CoreGraphics
import IOKit.hid

/// Which behaviour a held shortcut triggers.
enum HotkeyAction {
    case dictate   // transcribe speech and type/insert it
    case assist    // transcribe speech, send to an LLM, show the answer
    case stream    // live-transcribe speech and type it into the field as you talk
}

/// Global hold-to-talk monitor for up to two user-recorded shortcuts: the
/// primary dictation `hotkey` and an optional `assistantHotkey`.
///
/// - A **modifier-only** shortcut is matched on exact modifier flags.
/// - A **chord with a key** swallows the key while held (so it doesn't type).
///
/// When either shortcut is a chord, the tap consumes events (needs
/// Accessibility); when both are modifier-only, a listen-only tap is enough
/// (Input Monitoring). Only the EXACT recorded shortcuts are ever acted on.
final class HotkeyMonitor {
    /// Fired with the action of the shortcut that just engaged / released.
    var onStart: ((HotkeyAction) -> Void)?
    var onStop: ((HotkeyAction) -> Void)?

    /// Primary dictation shortcut. Change live; the tap re-arms if needed.
    var hotkey: Hotkey = Settings.shared.hotkey {
        didSet { hotkeysChanged() }
    }

    /// Optional assistant shortcut (nil = assistant mode off).
    var assistantHotkey: Hotkey? = Settings.shared.assistantHotkey {
        didSet { hotkeysChanged() }
    }

    /// Optional live-streaming dictation shortcut (nil = streaming mode off).
    var streamHotkey: Hotkey? = Settings.shared.streamHotkey {
        didSet { hotkeysChanged() }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?
    private var healthTimer: Timer?
    private var installedConsuming = false

    private var activeAction: HotkeyAction?    // shortcut currently held
    private var engagedKeyCode: UInt16?        // consumed chord key's keycode
    private var hasReceivedEvent = false

    // MARK: - Targets

    private struct Target { let hotkey: Hotkey; let action: HotkeyAction }

    private var targets: [Target] {
        var t = [Target(hotkey: hotkey, action: .dictate)]
        if let a = assistantHotkey { t.append(Target(hotkey: a, action: .assist)) }
        if let s = streamHotkey { t.append(Target(hotkey: s, action: .stream)) }
        return t
    }

    /// True when any shortcut is a chord (has a key), so the tap must consume.
    private var needsConsume: Bool {
        targets.contains { !$0.hotkey.isModifierOnly }
    }

    // MARK: - Lifecycle

    func start() {
        // Ask for both permissions up front: modifier-only needs Input
        // Monitoring, a chord needs Accessibility.
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        _ = Self.ensureAccessibility(prompt: false)
        NSLog("Slive: InputMonitoring=\(Self.inputMonitoringGranted) Accessibility=\(AXIsProcessTrusted())")

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

    /// Whether the permission the current tap mode needs is granted.
    private var tapGranted: Bool {
        needsConsume ? AXIsProcessTrusted() : Self.inputMonitoringGranted
    }

    /// A recorded shortcut changed: release any held action and re-arm the tap
    /// if the listen/consume mode changed.
    private func hotkeysChanged() {
        if let a = activeAction { activeAction = nil; engagedKeyCode = nil; onStop?(a) }
        if needsConsume != installedConsuming { reinstallTap() }
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
        let consuming = needsConsume
        let option: CGEventTapOptions = consuming ? .defaultTap : .listenOnly
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
        installedConsuming = consuming
        startHealthCheck()
        NSLog("Slive: ✅ hotkey tap installed (\(consuming ? "consume" : "listen")).")
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
                NSLog("Slive: permission granted — re-arming hotkey tap.")
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
        // Ignore the synthetic keystrokes Slive itself types (live dictation types
        // into the field WHILE the stream key is held). They carry no modifiers, so
        // without this the modifier-only matcher would read them as "key released"
        // and stop the stream. PasteEngine tags them with this marker.
        if event.getIntegerValueField(.eventSourceUserData) == PasteEngine.syntheticMarker {
            return false
        }
        markActive()

        let flags = event.flags.rawValue & Hotkey.modifierMask
        let keycode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

        // 1. Chord shortcuts (a key + modifiers) — these consume the key.
        switch type {
        case .keyDown:
            for t in targets where !t.hotkey.isModifierOnly {
                if keycode == t.hotkey.keyCode && flags == t.hotkey.modifiers {
                    engage(t.action, engagedKey: keycode)
                    return true    // swallow (incl. autorepeat) so it never types
                }
            }
        case .keyUp:
            if let ek = engagedKeyCode, keycode == ek {
                engagedKeyCode = nil
                release()
                return true        // swallow the matching key-up too
            }
        case .flagsChanged:
            // A chord is engaged and a required modifier was released → stop, but
            // keep swallowing the key's eventual key-up via `engagedKeyCode`.
            if engagedKeyCode != nil,
               let a = activeAction,
               let t = targets.first(where: { $0.action == a }),
               flags != t.hotkey.modifiers {
                if let held = activeAction { activeAction = nil; onStop?(held) }
            }
        default:
            break
        }

        // 2. Modifier-only shortcuts — matched on exact flags. Skipped while a
        //    chord is engaged (that engagement owns `activeAction`).
        if engagedKeyCode == nil {
            let matched = targets.first {
                $0.hotkey.isModifierOnly
                    && $0.hotkey.modifiers != 0
                    && $0.hotkey.modifiers == flags
            }?.action
            if matched != activeAction {
                if let a = activeAction { activeAction = nil; onStop?(a) }
                if let m = matched { activeAction = m; onStart?(m) }
            }
        }
        return false
    }

    /// Engage a chord action, releasing any previously-held action first.
    private func engage(_ action: HotkeyAction, engagedKey: UInt16) {
        if let a = activeAction, a != action { activeAction = nil; onStop?(a) }
        engagedKeyCode = engagedKey
        if activeAction != action { activeAction = action; onStart?(action) }
    }

    /// Release whatever action is currently held.
    private func release() {
        if let a = activeAction { activeAction = nil; onStop?(a) }
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
