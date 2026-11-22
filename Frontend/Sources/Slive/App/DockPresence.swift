import AppKit

/// Whether Slive shows in the Dock and ⌘-Tab. "Show in Dock" off = menu bar
/// only, while the shortcut keeps working (the app still runs). The Settings
/// window brings the icon back while it's open: a window with no Dock icon
/// can't be ⌘-Tabbed to and gets lost behind other apps.
@MainActor
enum DockPresence {
    static func policy(showInDock: Bool, windowOpen: Bool) -> NSApplication.ActivationPolicy {
        showInDock || windowOpen ? .regular : .accessory
    }

    /// Apply the policy for the current setting and Settings window.
    static func apply(windowOpen: Bool? = nil) {
        let wanted = policy(showInDock: Settings.shared.showInDock,
                            windowOpen: windowOpen ?? SettingsWindowController.isOpen)
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }
}
