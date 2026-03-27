// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CameraKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CameraKit", targets: ["CameraKit"]),
    ],
    dependencies: [
        .package(path: "../CopilotSDK"),
    ],
    targets: [
        .target(
            name: "CameraKit",
            dependencies: ["CopilotSDK"],
            path: "Sources"
        ),
        .testTarget(
            name: "CameraKitTests",
            dependencies: ["CameraKit"],
            path: "Tests"
        ),
    ]
)
