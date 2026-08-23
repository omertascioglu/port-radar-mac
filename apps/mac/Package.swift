// swift-tools-version: 6.0
// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution.
import PackageDescription

let package = Package(
    name: "DevPort",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DevPort",
            path: "Sources/DevPort"
        ),
        .testTarget(
            name: "DevPortTests",
            dependencies: ["DevPort"],
            path: "Tests/DevPortTests"
        )
    ]
)
