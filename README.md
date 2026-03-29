# copilot-ios

Swift packages for building AI-powered iOS apps with GitHub Copilot. Includes an MCP client SDK, native UI automation, AI-directed camera, and WebKit browser automation.

**Production relay:** `wss://relay.ai.qili2.com` (default)

## Packages

| Package | Purpose | Deps | Sources | Tests |
|---------|---------|------|---------|-------|
| **CopilotSDK** | MCP client, JSON-RPC, 3 transports (WebSocket, TCP, Stdio) | None | 6 | 5 |
| **AppAgent** | Native iOS UI automation via accessibility + MCP server | None | 5 | 2 (35 tests) |
| **CameraKit** | AI-directed camera with cloud + on-device backends | CopilotSDK | 9 | 1 |
| **WebKitAgent** | WebKit browser automation, DOM snapshots | CopilotSDK | 4 | 6 |

## Quick Start

```swift
import CopilotSDK

// Connect to production relay (wss://relay.ai.qili2.com)
let transport = WebSocketTransport()
let client = CopilotClient(transport: transport)
try await client.start()

// Create an agent with custom tools
let agent = try await client.createAgent(config: AgentConfig(
    instructions: "You are a helpful assistant.",
    tools: [myTool],
    onResponse: { message in print("Agent:", message) },
    onAskUser: { question in return getUserInput(question) }
))
try await agent.run(prompt: "Hello!")
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  copilot-ios monorepo                                       │
│                                                             │
│  CopilotSDK (leaf)          AppAgent (leaf)                 │
│  ├── CopilotClient          ├── MCPServer (HTTP)            │
│  ├── CopilotSession         ├── AccessibilityScanner        │
│  ├── CopilotAgent           ├── InteractionEngine           │
│  ├── WebSocketTransport     └── AppAgentToolProvider        │
│  ├── TCPTransport               9 tools: snapshot, tap,     │
│  ├── StdioTransport             type, swipe, find, etc.     │
│  └── Types/Connection                                       │
│       │                                                     │
│  CameraKit (→ CopilotSDK)  WebKitAgent (→ CopilotSDK)      │
│  ├── CameraService          ├── DOMSnapshot                 │
│  ├── SceneAnalyzer          ├── WebAgentToolProvider        │
│  ├── VoiceService           ├── WebAgentView                │
│  ├── CameraToolProvider     └── WebViewManager              │
│  ├── CameraAnimator                                         │
│  ├── CameraSkill                                            │
│  ├── AppleCameraTools                                       │
│  ├── MultiCamService                                        │
│  └── ARSceneUnderstanding                                   │
└─────────────────────────────────────────────────────────────┘
         │                              │
    WebSocket/TCP                  HTTP MCP
         │                              │
    relay.ai.qili2.com:443         Device :9223
    (Caddy → relay-server.js)      (on-device server)
```

## CopilotSDK

Swift port of the official [`@github/copilot-sdk`](https://github.com/github/copilot-sdk). Full JSON-RPC MCP client with three transport backends.

**Key types:** `CopilotClient`, `CopilotSession`, `CopilotAgent`, `AgentConfig`, `SessionConfig`

**Transports:**
- `WebSocketTransport()` — default: `wss://relay.ai.qili2.com` (port 443 = wss, else ws)
- `WebSocketTransport(host:port:)` — custom relay
- `TCPTransport(host:port:)` — direct TCP to CLI
- `StdioTransport(executablePath:)` — spawn CLI process (macOS only)

**Features:**
- Session management: `createSession()`, `resumeSession()`, `sendAndWait()`
- Agent mode: `createAgent()` with `send_response`/`ask_user` tools auto-injected
- Tool definitions with JSON Schema parameters
- Streaming events, system message customization, model selection
- Relay v2: `clientId` pinning, `appId` workspace routing, hold/resume, snapshots

**Docs:** [CopilotSDK/docs/README.md](copilot-ios/CopilotSDK/docs/README.md) (714 lines, full API reference)

## AppAgent

Drop-in MCP server for native iOS UI automation. Embeds a Streamable HTTP server that exposes accessibility-based tools for remote control and testing.

**Key types:** `MCPServer`, `AppAgentToolProvider`, `AccessibilityScanner`, `InteractionEngine`

**MCP Tools (9):**
| Tool | Description |
|------|-------------|
| `snapshot` | Accessibility tree of current screen |
| `tap` | Tap element by accessibility ref |
| `type` | Type text into element |
| `swipe` | Swipe in direction |
| `long_press` | Long press element |
| `find` | Find element by text |
| `scroll_to` | Scroll to element |
| `pick` | Pick value from picker |
| `screenshot` | Take PNG screenshot |

**Transport:** HTTP on port 9223 (Streamable HTTP MCP protocol: POST/GET/DELETE on `/mcp`)

## CameraKit

AI-directed camera operator with dual backend support: cloud (CopilotSDK → relay → GPT-4.1) and on-device (Apple Foundation Models, iOS 26+).

**Key types:** `CameraService`, `SceneAnalyzer`, `VoiceOutput`, `VoiceInput`, `CameraToolProvider`, `CameraAnimator`, `MultiCamService`, `ARSceneUnderstanding`

**Tool modes:**

| Mode | Tools | Best for |
|------|-------|----------|
| **Granular** | 32 | Cloud models, fine-grained control |
| **Compact** | 14 | Fewer round-trips |
| **Apple FM** | 6 | On-device, offline, privacy-first |

**Skill presets:** Film Director, Portrait Photographer, Scene Scout, Timelapse Operator, Product Photographer

**Camera animation:** Keyframe-based system with easing (ease-in-out, spring) for smooth programmatic camera movements.

**Docs:** [CameraKit/docs/](copilot-ios/CameraKit/docs/) (4 design docs)

## WebKitAgent

WebKit browser automation via DOM snapshots and tool-based interaction. Provides a SwiftUI `WebAgentView` for embedding a controllable web view.

**Key types:** `DOMSnapshot`, `WebAgentToolProvider`, `WebAgentView`, `WebViewManager`

**Docs:** [WebKitAgent/docs/design.md](copilot-ios/WebKitAgent/docs/design.md)

## Usage

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lalalic/copilot-ios.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "CopilotSDK", package: "copilot-ios"),
            .product(name: "AppAgent", package: "copilot-ios"),
            .product(name: "CameraKit", package: "copilot-ios"),
            .product(name: "WebKitAgent", package: "copilot-ios"),
        ]
    ),
]
```

Or in Xcode: File → Add Package Dependencies → paste the repo URL → select the libraries you need.

For local development (Xcode project):
```swift
.package(path: "../copilot-ios")
```

## Requirements

- Swift 6.0+, strict concurrency
- iOS 18+ / macOS 15+
- iOS 26+ for CameraKit on-device Apple FM backend
- Xcode 16+

## Build & Test

```bash
# Build all packages
cd copilot-ios && swift build

# Test all
swift test

# Test individual package
cd CopilotSDK && swift test
cd AppAgent && swift test
cd CameraKit && swift test
cd WebKitAgent && swift test
```

### Integration tests

CopilotSDK includes integration tests against the live relay:

```bash
cd CopilotSDK && swift test --filter RemoteAgent    # tests against relay.ai.qili2.com
cd CopilotSDK && swift test --filter LocalAgent     # tests using local CLI via stdio (macOS)
```

Override relay with env vars: `RELAY_HOST=localhost RELAY_PORT=8765 swift test`

## Relay Server

The production relay at `relay.ai.qili2.com:443` pools Copilot CLI sessions and provides WebSocket access.

See [copilot-relay](https://github.com/lalalic/copilot-relay) for deployment, architecture, and configuration.

## Repository

- **GitHub:** [github.com/lalalic/copilot-ios](https://github.com/lalalic/copilot-ios)
- **Tag:** `1.0.0` (initial release)
- **License:** MIT
