// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "limitgauge",
    platforms: [.macOS("26.0")],
    targets: [
        // Everything that does not need a window: credentials, API client, model, scheduling.
        .target(
            name: "LimitGaugeCore",
            path: "Sources/LimitGaugeCore"
        ),
        .testTarget(
            name: "LimitGaugeCoreTests",
            dependencies: ["LimitGaugeCore"],
            path: "Tests/LimitGaugeCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
