# Copilot Instructions for copilot-ios

## Project Overview

copilot-ios is a Swift Package (SPM) containing reusable frameworks for the Neox iOS app.

## Architecture

```
copilot-ios/
├── CopilotSDK/     — Core: relay client, MCP tools, sessions, file I/O
├── CopilotChat/    — Chat UI components (SwiftUI)
├── WebKitAgent/    — Browser automation via WKWebView + site adapters
├── AppAgent/       — iOS accessibility automation (MCP server on :9223)
├── CameraKit/      — Camera capture utilities
└── MediaKit/       — FFmpeg-based media processing
```

## Build & Test

```bash
swift build          # macOS build (all targets)
swift test           # macOS tests (all targets)
```

For iOS:
```bash
xcodebuild build -scheme WebKitAgent -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild test  -scheme WebKitAgent -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Coding Standards

- **Swift 6.0** with strict concurrency (`@MainActor`, `Sendable`)
- **Platforms**: iOS 18+, macOS 15+
- **No UIKit** in library code — use `#if os(iOS)` guards for platform-specific APIs
- **Test-driven**: Write tests before implementation. All PRs must pass `swift test`.
- Prefer value types (`struct`, `enum`) over classes
- Use `async/await` — no completion handlers
- Keep individual files under 500 lines

## WebKitAgent Specifics

- Site adapters are YAML-based (loaded from bundle + user directory)
- `AdapterRegistry` manages adapter discovery
- `WebViewManager` handles WKWebView lifecycle and cookie management
- Auth framework: `AuthStrategy` enum (`.none`, `.cookie(domain)`, `.header(name, value)`)
- WeChat channel: `Sources/WeChat/` — WechatyBro injection, message polling, QR code

## PR Guidelines

- Keep PRs focused: one feature or fix per PR
- Under 500 line changes for auto-merge eligibility
- Don't modify `Package.swift` dependency versions without discussion
- Don't touch `.env`, secrets, or credentials files
- Include test coverage for new code
