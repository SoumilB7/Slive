// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flowy",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Flowy",
            path: "Sources/Flowy",
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
