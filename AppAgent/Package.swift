// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppAgent",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AppAgent", targets: ["AppAgent"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "AppAgent",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "AppAgentTests",
            dependencies: ["AppAgent"],
            path: "Tests"
        ),
    ]
)
