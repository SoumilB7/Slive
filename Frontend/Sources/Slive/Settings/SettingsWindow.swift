import AppKit
import SwiftUI

/// Owns the Settings/home window. Slive is a normal app (persistent Dock icon),
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
                contentRect: NSRect(origin: .zero, size: SliveTheme.windowDefault),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Slive"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.collectionBehavior = [.fullScreenPrimary]   // allow entering full screen
            w.minSize = SliveTheme.windowMin              // single source of truth
            w.backgroundColor = NSColor(white: 0.10, alpha: 1)
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.center()
            // Remember the user's chosen size/position across launches.
            w.setFrameAutosaveName("SliveSettings")
            w.delegate = self
            window = w
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
