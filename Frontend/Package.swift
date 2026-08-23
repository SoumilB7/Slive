// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Slive",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // On-device speech-to-text on the Apple Neural Engine (Core ML).
        // Pinned: newer WhisperKit pulls a swift-transformers that fails to
        // compile on the Command Line Tools toolchain.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.9.0"))
    ],
    targets: [
        // Tiny Objective-C shim: the only way to catch the NSExceptions
        // AVAudioEngine raises (Swift can't), so a refused mic can't abort
        // the process.
        .target(
            name: "SliveObjC",
            path: "Sources/SliveObjC"
        ),
        .executableTarget(
            name: "Slive",
            dependencies: [
                "SliveObjC",
                .product(name: "WhisperKit", package: "WhisperKit")
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
