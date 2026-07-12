import AppKit
import SwiftUI

/// Owns the Settings/home window. Flowy is a normal app (persistent Dock icon),
/// so closing this window just hides it — the app keeps running.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    var onRelaunch: () -> Void = {}

    private var window: NSWindow?
    private let permissions = PermissionsModel()

    func show() {
        if window == nil {
            let root = SettingsView(
                settings: .shared,
                permissions: permissions,
                onRelaunch: onRelaunch
            )
            let hosting = NSHostingView(rootView: root)

            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Flowy"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.collectionBehavior = [.fullScreenNone]   // don't stick to fullscreen apps
            w.backgroundColor = NSColor(white: 0.10, alpha: 1)
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.center()
            w.delegate = self
            window = w
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
