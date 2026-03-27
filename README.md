# copilot-ios

Shared Swift packages for iOS Copilot apps.

## Packages

| Package | Description | Dependencies |
|---------|-------------|-------------|
| **CopilotSDK** | MCP client, JSON-RPC connection, transports (WebSocket, TCP, Stdio) | None |
| **AppAgent** | Native iOS UI automation via accessibility APIs | None |
| **CameraKit** | Camera service, scene analysis, camera skills, voice/TTS | CopilotSDK |
| **WebKitAgent** | WebKit browser automation, DOM snapshots | CopilotSDK |

## Usage

Add to your project's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lalalic/copilot-ios.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "CopilotSDK", package: "copilot-ios"),
            .product(name: "CameraKit", package: "copilot-ios"),
            // ... pick what you need
        ]
    ),
]
```

Or in Xcode: File → Add Package Dependencies → paste the repo URL → select the libraries you need.

## Requirements

- Swift 6.0+
- iOS 18+ / macOS 15+
