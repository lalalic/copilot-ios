// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotSDK",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CopilotSDK", targets: ["CopilotSDK"]),
    ],
    targets: [
        .target(
            name: "CopilotSDK",
            path: "Sources"
        ),
        .testTarget(
            name: "CopilotSDKTests",
            dependencies: ["CopilotSDK"],
            path: "Tests"
        ),
    ]
)
