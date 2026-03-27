# AppAgent

A self-contained Swift package that gives any iOS app remote UI automation via [MCP](https://modelcontextprotocol.io) (Model Context Protocol).

Drop it into your project, start the server, and control your app remotely from VS Code, Claude Desktop, or any MCP client.

## Quick Start

```swift
import AppAgent

// In your App/SceneDelegate:
let server = MCPServer(name: "my-app", port: 9223)
let agent = AppAgentToolProvider()
server.register(tools: agent.tools)
try server.start()
```

Connect from VS Code (`.vscode/mcp.json`):
```json
{
  "servers": {
    "my-app": { "url": "http://<device-ip>:9223/mcp" }
  }
}
```

## Requirements

- iOS 18+ / macOS 15+
- Swift 6.0+
- Zero external dependencies

## Architecture

```
AppAgent/
├── Sources/
│   ├── Server.swift              # MCP server (Streamable HTTP over Network.framework)
│   ├── Types.swift               # JSONValue, ToolDefinition, ToolHandler
│   ├── AppAgentToolProvider.swift # 8 sub-commands as a single MCP tool
│   ├── AccessibilityScanner.swift # UIView hierarchy → tree-structured snapshot
│   └── InteractionEngine.swift   # Tap, type, swipe, scroll via UIKit APIs
└── Tests/
    ├── AppAgentTests.swift       # 20 XCTest tests (tool dispatch, validation)
    └── MCPServerTests.swift      # 15 Swift Testing tests (server, JSON conversion)
```

## Commands

The package exposes a single `app_agent` tool with these sub-commands:

| Command | Params | Description |
|---------|--------|-------------|
| `snapshot` | — | Scan screen for interactive elements. Returns tree with refs (r0, r1, r2…) |
| `tap` | `ref` | Tap an element by ref |
| `type` | `ref`, `text`, `clear?` | Type into a text field. `clear` defaults to true |
| `swipe` | `direction`, `ref?` | Swipe up/down/left/right. Optional ref for element-specific swipe |
| `long_press` | `ref`, `duration?` | Long-press an element. Duration in seconds (default 1.0) |
| `find` | `text` | Search elements by label/value text match |
| `scroll_to` | `ref` | Scroll to make an element visible |
| `pick` | `ref`, `value`, `component?` | Select value in picker, date picker, or segmented control |
| `screenshot` | — | Take screenshot, returns base64 JPEG |

**Workflow:** `snapshot` → read refs → `tap`/`type`/`swipe` → `snapshot` again

### Picker Selection

The `pick` command supports three UIKit picker types:

| Type | Value Format | Example |
|------|-------------|---------|
| `UIPickerView` | Text match or row index | `"California"` or `"3"` |
| `UIDatePicker` | Date string | `"2025-03-26"`, `"2025-03-26 14:30"`, `"14:30"` |
| `UISegmentedControl` | Segment title or index | `"Monthly"` or `"1"` |

Use `component` for multi-column picker views (default: 0). The command walks the view hierarchy upward to find the nearest picker ancestor if the ref points to a child element.

## Snapshot Output

The `snapshot` command returns a tree-structured view of the UI:

```
[MyApp] (393x852)
  [NavigationBar] My Screen
    r0 Button "Back"
    r1 Button "Settings"
  [ScrollView]
    r2 StaticText "Welcome"
    r3 TextField "Email" = ""
    r4 SecureTextField "Password"
    r5 Button "Sign In"
  [Tab Bar]
    r6 Button "Home" [selected]
    r7 Button "Profile"
```

## MCP Protocol

The server implements [MCP Streamable HTTP](https://spec.modelcontextprotocol.io/specification/2025-03-26/basic/transports/#streamable-http) transport:

- **POST /mcp** — JSON-RPC 2.0 (initialize, tools/list, tools/call, ping)
- **GET /** — Server info
- **DELETE /mcp** — Session termination
- **OPTIONS /mcp** — CORS preflight

## API Reference

### MCPServer

```swift
@MainActor
public final class MCPServer {
    public init(name: String = "mcp-server", version: String = "1.0.0", port: UInt16 = 9223)
    
    public func register(tools: [ToolDefinition])
    public func register(name: String, description: String, inputSchema: [String: Any], handler: @escaping ToolHandler)
    public func unregister(name: String)
    
    public func start() throws
    public func stop()
    
    public var toolNames: [String]
    @Published public private(set) var isRunning: Bool
    public var onLog: ((String) -> Void)?
    
    // JSON conversion utilities
    nonisolated public static func toJSONValue(_ value: Any) -> JSONValue
    nonisolated public static func jsonValueToAny(_ value: JSONValue) -> Any
}
```

### AppAgentToolProvider

```swift
@MainActor  // iOS only
public final class AppAgentToolProvider {
    public init()
    public var tools: [ToolDefinition]
    public let scanner: AccessibilityScanner
    public let engine: InteractionEngine
    public static let skillPrompt: String
}
```

### AccessibilityScanner

```swift
@MainActor  // iOS only
public final class AccessibilityScanner {
    public func scan() -> String              // Tree-structured snapshot
    public var elements: [AppElement]          // Last scan results
    public func element(ref: String) -> AppElement?
}
```

### InteractionEngine

```swift
@MainActor  // iOS only
public final class InteractionEngine {
    public func tap(ref: String) -> String
    public func type(ref: String, text: String, clear: Bool) -> String
    public func swipe(direction: String, ref: String?) -> String
    public func longPress(ref: String, duration: Double) -> String
    public func find(text: String) -> String
    public func scrollTo(ref: String) -> String
    public func pick(ref: String, value: String, component: Int) -> String
    public func screenshot(quality: Double) -> String
}
```

## Installation

Add as a local Swift package dependency:

```swift
// Package.swift
dependencies: [
    .package(path: "../AppAgent"),
]
```

Or in Xcode: File → Add Package Dependencies → Add Local → select `AppAgent/`.

## Testing

```bash
cd AppAgent && swift test
# 35 tests (20 XCTest + 15 Swift Testing)
```
