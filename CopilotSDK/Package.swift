// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotSDK",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CopilotSDK", targets: ["CopilotSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.18"),
    ],
    targets: [
        .target(
            name: "CopilotSDK",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "CopilotSDKTests",
            dependencies: ["CopilotSDK"],
            path: "Tests"
        ),
    ]
)
