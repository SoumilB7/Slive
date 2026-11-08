import SwiftUI
import AppKit
import CoreGraphics

/// Records a push-to-talk shortcut: click Record, then press any combo — a
/// modifier alone (fn, ⌥, ⌃⌥, …) or a chord with a key (⌥ + /). Uses a local
/// NSEvent monitor (the Settings window is focused during recording), so it
/// needs no special permission and never leaks the keys into the app.
struct HotkeyRecorderView: View {
    /// The page's env settings (in memory in the Settings render self-test).
    @ObservedObject var settings: Settings
    /// Which shortcut this recorder edits.
    var target: BindingSlot = .dictation
    var title: String = "Shortcut"
    /// Optional idle line under the title; the recording prompt replaces it.
    var subtitle: String = ""

    @State private var recording = false
    @State private var monitor: Any?
    @State private var maxModifiers: UInt64 = 0
    /// Double-tap capture (toggle targets only): after the first full
    /// release we wait a beat for a second tap before committing ×1.
    @State private var pendingTapMods: UInt64 = 0
    @State private var commitWork: DispatchWorkItem?

    /// Toggle binds may be a double-tap; hold binds are always a single hold.
    private var supportsDoubleTap: Bool { target.style == .toggle }

    /// Current shortcut for this target (assistant may be unset).
    private var current: Hotkey? { settings.shortcut(for: target) }

    /// Optional shortcuts (assistant, stream) can be cleared back to
    /// disabled; the primary key can't be unset.
    private var isClearable: Bool { !(target.spec?.required ?? true) }

    private var buttonLabel: String {
        if recording { return "Recording…" }
        return current?.label ?? "Record"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                if recording || !subtitle.isEmpty {
                    Text(recording
                         ? (supportsDoubleTap
                            ? "Press a key. Double-tap for ×2. Esc cancels."
                            : "Press a key or combo. Esc cancels.")
                         : subtitle)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if isClearable && current != nil && !recording {
                Button {
                    clearShortcut()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SliveTheme.textFaint)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            Button {
                recording ? cancel() : startRecording()
            } label: {
                HStack(spacing: 6) {
                    if recording {
                        StatusDot(color: .white, pulses: true, size: 7)
                    }
                    Text(buttonLabel)
                        .font(SliveTheme.rowFont)
                }
                .frame(minWidth: 108)
            }
            .buttonStyle(.borderedProminent)
            .tint(recording ? SliveTheme.warn : SliveTheme.accent)
        }
        // Switching pages (or closing Settings) mid-recording must not leave
        // the monitor behind — it swallows every key the app sees.
        .onDisappear { if recording { cancel() } }
    }

    // MARK: - Recording

    private func startRecording() {
        recording = true
        maxModifiers = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil   // swallow everything while recording
        }
    }

    private func cancel() {
        recording = false
        commitWork?.cancel(); commitWork = nil
        pendingTapMods = 0
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func commit(_ hotkey: Hotkey) {
        settings.setShortcut(hotkey, for: target)
        cancel()
    }

    private func clearShortcut() {
        guard isClearable else { return }
        settings.setShortcut(nil, for: target)
    }

    private func handle(_ event: NSEvent) {
        let mods = UInt64(event.modifierFlags.rawValue) & Hotkey.modifierMask

        switch event.type {
        case .flagsChanged:
            maxModifiers |= mods
            // All modifiers released with no key pressed → a modifier-only shortcut.
            if mods == 0 && maxModifiers != 0 {
                let released = maxModifiers
                maxModifiers = 0
                guard supportsDoubleTap else {
                    commit(Self.modifierHotkey(released, taps: 1))
                    return
                }
                // Second tap of the same gesture inside the window → ×2.
                if pendingTapMods == released {
                    commitWork?.cancel(); commitWork = nil
                    pendingTapMods = 0
                    commit(Self.modifierHotkey(released, taps: 2))
                    return
                }
                // First tap: hold the commit briefly — tap again for ×2.
                pendingTapMods = released
                let work = DispatchWorkItem {
                    pendingTapMods = 0
                    commitWork = nil
                    commit(Self.modifierHotkey(released, taps: 1))
                }
                commitWork = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Hotkey.doubleTapInterval, execute: work)
            }

        case .keyDown:
            switch Self.keyDownOutcome(keyCode: event.keyCode, modifiers: mods,
                                       characters: event.charactersIgnoringModifiers) {
            case .cancel: cancel()
            case .ignore: break
            case .commit(let hotkey): commit(hotkey)
            }

        default:
            break
        }
    }

    // MARK: - Pure recording rules (self-tested against the monitor)

    enum KeyOutcome: Equatable {
        case cancel
        /// Keep waiting (a bare typing key would hijack that key).
        case ignore
        case commit(Hotkey)
    }

    /// A key pressed while recording, with the (masked) modifiers its event
    /// carried. Esc cancels; a bare typing key is ignored; function keys,
    /// arrows and anything with a modifier is recorded.
    static func keyDownOutcome(keyCode: UInt16, modifiers: UInt64, characters: String?) -> KeyOutcome {
        if keyCode == 53 { return .cancel }
        if modifiers == 0 && !Hotkey.isSpecialKey(keyCode) { return .ignore }
        let keyChar = Hotkey.keyChar(forKeyCode: keyCode, characters: characters)
        let label = Hotkey.makeLabel(modifiers: modifiers, keyChar: keyChar)
        return .commit(Hotkey(modifiers: modifiers, keyCode: keyCode, label: label))
    }

    /// A modifier-only shortcut, once every modifier is released.
    static func modifierHotkey(_ modifiers: UInt64, taps: Int) -> Hotkey {
        let label = Hotkey.makeLabel(modifiers: modifiers, keyChar: nil) + (taps >= 2 ? " ×2" : "")
        return Hotkey(modifiers: modifiers, keyCode: nil, label: label, taps: taps)
    }
}
