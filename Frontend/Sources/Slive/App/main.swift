import AppKit

// `Slive --self-test` runs the built-in check suite (Sources/Slive/SelfTest.swift)
// and exits — no windows, no permissions, no app boot. This exists because the
// Command Line Tools toolchain has neither XCTest nor Swift Testing; the checks
// run inside the real module, on the real code paths.
if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated { SelfTest.runAndExit() }
}

// `Slive --gauntlet`: the Gauntlet (Sources/Slive/Gauntlet), same rules as
// --self-test — fakes only, no app boot.
if CommandLine.arguments.contains("--gauntlet") {
    MainActor.assumeIsolated { GauntletRunner.runAndExit() }
}

// Dev CLIs (`--bench-*`, `--prepare-models`, …): table in DevTools/DevCommand.swift.
if let command = DevCommands.match(CommandLine.arguments) {
    Task { @MainActor in
        exit(await command.run(CommandLine.arguments))
    }
    dispatchMain()
}

// Slive — a hold-to-talk mic overlay. A normal app (Dock icon, ⌘-Tab, ⌘-Q,
// minimizable window) unless "Show in Dock" is off: then menu bar only. The
// hold-to-talk overlay works everywhere either way.
let app = NSApplication.shared
// main.swift's entry runs on the main thread; assert it so the @MainActor
// AppDelegate can be constructed here.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// Before run(), so a menu-bar-only Slive never flashes a Dock icon at launch.
MainActor.assumeIsolated { DockPresence.apply(windowOpen: false) }
app.run()
