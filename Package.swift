// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OsobnyPomocnik",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
        // test/local-whisper-sk only — see CLAUDE.md. Local on-device transcription
        // experiment; not meant to survive a merge back to master unless the test succeeds.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "OsobnyPomocnik",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/OsobnyPomocnik",
            exclude: ["Resources/Info.plist"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
