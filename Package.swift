// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OsobnyPomocnik",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OsobnyPomocnik",
            path: "Sources/OsobnyPomocnik",
            exclude: ["Resources/Info.plist"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
