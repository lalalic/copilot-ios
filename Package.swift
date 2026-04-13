// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "copilot-ios",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CopilotSDK", targets: ["CopilotSDK"]),
        .library(name: "CopilotChat", targets: ["CopilotChat"]),
        .library(name: "CameraKit", targets: ["CameraKit"]),
        .library(name: "WebKitAgent", targets: ["WebKitAgent"]),
        .library(name: "AppAgent", targets: ["AppAgent"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "NeoxCore", targets: ["NeoxCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/yangliu-1995/ffmpeg-kit-spm.git", exact: "6.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.18"),
        .package(name: "ios-system-lite", path: "Packages/ios-system-lite"),
    ],
    targets: [
        // MARK: - CopilotSDK (leaf, no dependencies)
        .target(
            name: "CopilotSDK",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "ios_system", package: "ios-system-lite"),
            ],
            path: "CopilotSDK/Sources",
            resources: [.copy("Resources/workspace.zip"), .copy("Resources/workspace")]
        ),
        .testTarget(
            name: "CopilotSDKTests",
            dependencies: ["CopilotSDK"],
            path: "CopilotSDK/Tests"
        ),

        // MARK: - CopilotChat (depends on CopilotSDK)
        .target(
            name: "CopilotChat",
            dependencies: ["CopilotSDK"],
            path: "CopilotChat/Sources",
            resources: [.copy("Resources/mermaid.html")]
        ),
        .testTarget(
            name: "CopilotChatTests",
            dependencies: ["CopilotChat"],
            path: "CopilotChat/Tests"
        ),

        // MARK: - AppAgent (leaf, no dependencies)
        .target(
            name: "AppAgent",
            path: "AppAgent/Sources"
        ),
        .testTarget(
            name: "AppAgentTests",
            dependencies: ["AppAgent"],
            path: "AppAgent/Tests"
        ),

        // MARK: - CameraKit (depends on CopilotSDK)
        .target(
            name: "CameraKit",
            dependencies: ["CopilotSDK"],
            path: "CameraKit/Sources"
        ),
        .testTarget(
            name: "CameraKitTests",
            dependencies: ["CameraKit"],
            path: "CameraKit/Tests"
        ),

        // MARK: - WebKitAgent (depends on CopilotSDK)
        .target(
            name: "WebKitAgent",
            dependencies: ["CopilotSDK"],
            path: "WebKitAgent/Sources"
        ),
        .testTarget(
            name: "WebKitAgentTests",
            dependencies: ["WebKitAgent"],
            path: "WebKitAgent/Tests"
        ),

        // MARK: - MediaKit (depends on CopilotSDK + ffmpeg-kit)
        .target(
            name: "MediaKit",
            dependencies: [
                "CopilotSDK",
                .product(name: "FFmpegKit-SPM", package: "ffmpeg-kit-spm"),
            ],
            path: "MediaKit/Sources"
        ),
        .testTarget(
            name: "MediaKitTests",
            dependencies: ["MediaKit"],
            path: "MediaKit/Tests"
        ),

        // MARK: - NeoxCore (depends on CopilotSDK + CopilotChat + AppAgent + WebKitAgent + MediaKit)
        .target(
            name: "NeoxCore",
            dependencies: ["CopilotSDK", "CopilotChat", "AppAgent", "WebKitAgent", "MediaKit"],
            path: "NeoxCore/Sources"
        ),
    ]
)
