import SwiftUI
import AppKit
import CoreGraphics

/// Records a push-to-talk shortcut: click Record, then press any combo — a
/// modifier alone (fn, ⌥, ⌃⌥, …) or a chord with a key (⌥ + /). Uses a local
/// NSEvent monitor (the Settings window is focused during recording), so it
/// needs no special permission and never leaks the keys into the app.
struct HotkeyRecorderView: View {
    @ObservedObject private var settings = Settings.shared
    var accent: Color

    @State private var recording = false
    @State private var monitor: Any?
    @State private var maxModifiers: UInt64 = 0

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Push-to-talk shortcut")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text(recording
                     ? "Press it now — a modifier alone, or a modifier + key (⌥ /). Esc cancels."
                     : "Hold this to talk. A modifier + key is suppressed while held.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(recording ? "Recording…" : settings.hotkey.label) {
                recording ? cancel() : startRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(recording ? .orange : accent)
            .controlSize(.large)
            .frame(minWidth: 96)
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
        settings.hotkey = hotkey
        cancel()
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
