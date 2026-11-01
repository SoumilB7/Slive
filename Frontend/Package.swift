// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Slive",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // On-device speech-to-text on the Apple Neural Engine (Core ML).
        // Pinned exactly. 0.10.2 is the newest that keeps swift-transformers
        // 0.1.8 (later ones pull a release that fails to compile on the
        // Command Line Tools toolchain), and it fixes 0.9's data race on the
        // decoder's early-stop flags — a real crash in the post-load warm-up
        // (EXC_BAD_ACCESS in TextDecoder.decodeText, Nov 5).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.10.2"),
        // NVIDIA Parakeet (FastConformer TDT) on the Neural Engine — the
        // "instant" engine (~50ms decodes vs Whisper's ~0.9s on this Mac).
        // Pinned exactly, like WhisperKit: a new release is a deliberate bump.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4")
    ],
    targets: [
        // Tiny Objective-C shim: the only way to catch the NSExceptions
        // AVAudioEngine raises (Swift can't), so a refused mic can't abort
        // the process.
        .target(
            name: "SliveObjC",
            path: "Sources/SliveObjC"
        ),
        // Problem reports: redaction, crash/hang parsing, the GitHub issue
        // body — shared by the app and its reporter, and self-tested.
        .target(
            name: "SliveReport",
            path: "Sources/SliveReport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The reporter: a separate process (Contents/Helpers/SliveReporter.app)
        // so a frozen or crashed Slive can still be reported.
        .executableTarget(
            name: "SliveReporter",
            dependencies: ["SliveReport"],
            path: "Sources/SliveReporter",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .executableTarget(
            name: "Slive",
            dependencies: [
                "SliveObjC",
                "SliveReport",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Slive",
            swiftSettings: [
                // Pragmatic: keep Swift 5 language mode to avoid strict-concurrency
                // friction between the audio thread and @MainActor UI updates.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate")
            ]
        )
    ]
)
