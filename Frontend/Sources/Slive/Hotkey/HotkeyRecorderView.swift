import SwiftUI
import AppKit
import CoreGraphics

/// Records a push-to-talk shortcut: click Record, then press any combo — a
/// modifier alone (fn, ⌥, ⌃⌥, …) or a chord with a key (⌥ + /). Uses a local
/// NSEvent monitor (the Settings window is focused during recording), so it
/// needs no special permission and never leaks the keys into the app.
struct HotkeyRecorderView: View {
    /// Which shortcut this recorder edits.
    enum Target { case dictation, assistant, stream }

    @ObservedObject private var settings = Settings.shared
    var target: Target = .dictation
    var title: String = "Push-to-talk shortcut"
    var subtitle: String = "Hold this to talk. A modifier + key is suppressed while held."

    @State private var recording = false
    @State private var monitor: Any?
    @State private var maxModifiers: UInt64 = 0

    /// Current shortcut for this target (assistant may be unset).
    private var current: Hotkey? {
        switch target {
        case .dictation: return settings.hotkey
        case .assistant: return settings.assistantHotkey
        case .stream:    return settings.streamHotkey
        }
    }

    /// Optional shortcuts (assistant, stream) can be cleared back to disabled.
    private var isClearable: Bool { target != .dictation }

    private var buttonLabel: String {
        if recording { return "Recording…" }
        return current?.label ?? "Record"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text(recording
                     ? "Press it now — a modifier alone, or a modifier + key (⌥ /). Esc cancels."
                     : subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isClearable && current != nil && !recording {
                Button {
                    clearShortcut()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Clear this shortcut")
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
            .tint(recording ? .orange : SliveTheme.accent)
        }
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
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func commit(_ hotkey: Hotkey) {
        switch target {
        case .dictation: settings.hotkey = hotkey
        case .assistant: settings.assistantHotkey = hotkey
        case .stream:    settings.streamHotkey = hotkey
        }
        cancel()
    }

    private func clearShortcut() {
        switch target {
        case .dictation: break                     // the primary key can't be unset
        case .assistant: settings.assistantHotkey = nil
        case .stream:    settings.streamHotkey = nil
        }
    }

    private func handle(_ event: NSEvent) {
        let mods = UInt64(event.modifierFlags.rawValue) & Hotkey.modifierMask

        switch event.type {
        case .flagsChanged:
            maxModifiers |= mods
            // All modifiers released with no key pressed → a modifier-only shortcut.
            if mods == 0 && maxModifiers != 0 {
                let label = Hotkey.makeLabel(modifiers: maxModifiers, keyChar: nil)
                commit(Hotkey(modifiers: maxModifiers, keyCode: nil, label: label))
            }

        case .keyDown:
            if event.keyCode == 53 { cancel(); return }   // Esc cancels
            // Ignore a bare typing key (would hijack that key); keep waiting for a
            // modifier. Function keys / arrows / Esc are fine bare.
            if mods == 0 && !Hotkey.isSpecialKey(event.keyCode) { return }
            let keyChar = Hotkey.keyChar(forKeyCode: event.keyCode,
                                         characters: event.charactersIgnoringModifiers)
            let label = Hotkey.makeLabel(modifiers: mods, keyChar: keyChar)
            commit(Hotkey(modifiers: mods, keyCode: event.keyCode, label: label))

        default:
            break
        }
    }
}
