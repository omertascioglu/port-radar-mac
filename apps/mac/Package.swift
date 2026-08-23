// swift-tools-version: 6.0
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
