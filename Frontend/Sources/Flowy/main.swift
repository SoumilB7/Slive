import AppKit

// Flowy — a hold-to-talk mic overlay. A normal app: Dock icon, Cmd-Tab,
// Cmd-Q, minimizable window; the hold-to-talk overlay still works everywhere.
let app = NSApplication.shared
// main.swift's entry runs on the main thread; assert it so the @MainActor
// AppDelegate can be constructed here.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
