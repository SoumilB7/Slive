import AppKit

// Flowy — a hold-to-talk mic overlay. A normal app: Dock icon, Cmd-Tab,
// Cmd-Q, minimizable window; the hold-to-talk overlay still works everywhere.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
