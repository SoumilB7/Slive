import AppKit

// Flowy — a hold-to-talk mic overlay. Runs as a menu-bar agent (no Dock icon).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
