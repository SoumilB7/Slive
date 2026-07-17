import AppKit

// `Slive --self-test` runs the built-in check suite (Sources/Slive/SelfTest.swift)
// and exits — no windows, no permissions, no app boot. This exists because the
// Command Line Tools toolchain has neither XCTest nor Swift Testing; the checks
// run inside the real module, on the real code paths.
if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated { SelfTest.runAndExit() }
}

// Slive — a hold-to-talk mic overlay. A normal app: Dock icon, Cmd-Tab,
// Cmd-Q, minimizable window; the hold-to-talk overlay still works everywhere.
let app = NSApplication.shared
// main.swift's entry runs on the main thread; assert it so the @MainActor
// AppDelegate can be constructed here.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
