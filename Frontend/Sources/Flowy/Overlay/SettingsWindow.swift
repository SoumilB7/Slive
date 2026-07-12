import AppKit
import SwiftUI

/// Owns the Settings/home window. While it's open Flowy behaves like a normal
/// app (dock icon, keyboard focus); when it closes we drop back to a quiet
/// menu-bar agent.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    var audiosPath: String = ""
    var onOpenAudios: () -> Void = {}

    private var window: NSWindow?
    private let permissions = PermissionsModel()

    func show() {
        if window == nil {
            let root = SettingsView(
                settings: .shared,
                permissions: permissions,
                audiosPath: audiosPath,
                onOpenAudios: onOpenAudios
            )
            let hosting = NSHostingView(rootView: root)

            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Flowy"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(white: 0.10, alpha: 1)
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.center()
            w.delegate = self
            window = w
        }

        NSApp.setActivationPolicy(.regular)      // dock icon + focus while open
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a quiet background agent.
        NSApp.setActivationPolicy(.accessory)
    }
}
