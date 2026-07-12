import AppKit

// Flowy — a hold-to-talk mic overlay. A normal app: Dock icon + menu-bar item.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
