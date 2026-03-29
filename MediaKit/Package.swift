// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "MediaKit", targets: ["MediaKit"]),
    ],
    dependencies: [
        .package(path: "../CopilotSDK"),
        .package(url: "https://github.com/yangliu-1995/ffmpeg-kit-spm.git", exact: "6.0.0"),
    ],
    targets: [
        .target(
            name: "MediaKit",
            dependencies: [
                "CopilotSDK",
                .product(name: "FFmpegKit-SPM", package: "ffmpeg-kit-spm"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "MediaKitTests",
            dependencies: ["MediaKit"],
            path: "Tests"
        ),
    ]
)
