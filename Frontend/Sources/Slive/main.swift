import AppKit

// `Slive --self-test` runs the built-in check suite (Sources/Slive/SelfTest.swift)
// and exits — no windows, no permissions, no app boot. This exists because the
// Command Line Tools toolchain has neither XCTest nor Swift Testing; the checks
// run inside the real module, on the real code paths.
if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated { SelfTest.runAndExit() }
}

// `Slive --bench-tail …` — would a shorter post-release capture lose words?
// (see TailBench.swift)
if CommandLine.arguments.contains("--bench-tail") {
    Task { @MainActor in
        exit(await TailBench.run(CommandLine.arguments))
    }
    dispatchMain()
}

// `Slive --prepare-models` — compile + warm the models for THIS binary, then
// exit. Run by build.sh before launch (see ModelPreparer.swift).
if CommandLine.arguments.contains("--prepare-models") {
    Task { @MainActor in
        exit(await ModelPreparer.run())
    }
    dispatchMain()
}

// `Slive --bench-coldstart …` — how slow are the first dictations after a
// (re)install, and does a stronger warm-up fix it? (see ColdStartBench.swift)
if CommandLine.arguments.contains("--bench-coldstart") {
    Task { @MainActor in
        exit(await ColdStartBench.run(CommandLine.arguments))
    }
    dispatchMain()
}

// `Slive --bench-compute …` — which chip (Neural Engine / GPU / CPU) should
// run each Whisper stage on this Mac (see ComputeBench.swift).
if CommandLine.arguments.contains("--bench-compute") {
    Task { @MainActor in
        exit(await ComputeBench.run(CommandLine.arguments))
    }
    dispatchMain()
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
