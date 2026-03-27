// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebKitAgent",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "WebKitAgent", targets: ["WebKitAgent"]),
    ],
    dependencies: [
        .package(path: "../CopilotSDK"),
    ],
    targets: [
        .target(
            name: "WebKitAgent",
            dependencies: ["CopilotSDK"],
            path: "Sources"
        ),
        .testTarget(
            name: "WebKitAgentTests",
            dependencies: ["WebKitAgent"],
            path: "Tests"
        ),
    ]
)
