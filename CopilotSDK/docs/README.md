# Copilot SDK for Swift

Swift SDK for programmatic control of GitHub Copilot CLI via JSON-RPC. Feature-complete port of the official [`@github/copilot-sdk`](https://github.com/github/copilot-sdk) for Node.js/TypeScript.

> **Note:** This SDK is in technical preview and may change in breaking ways.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lalalic/copilot-ios.git", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "CopilotSDK", package: "copilot-ios"),
    ]),
]
```

Or add as a local package:

```swift
dependencies: [
    .package(path: "../copilot-ios"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "CopilotSDK", package: "copilot-ios"),
    ]),
]
```

**Requirements:** Swift 6.0+, iOS 18+ / macOS 15+

## Quick Start

```swift
import CopilotSDK

// Connect via WebSocket relay (defaults to wss://relay.ai.qili2.com)
let transport = WebSocketTransport()
let client = CopilotClient(transport: transport)
try await client.start()

// Create a session
let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1"
))

// Send and wait for response
let response = try await session.sendAndWait(prompt: "What is 2+2?", timeout: 60)
print(response ?? "no response")

// Clean up
try await session.disconnect()
client.stop()
```

### Using a custom relay

```swift
// Local relay server
let transport = WebSocketTransport(host: "localhost", port: 8765)

// Or a custom URL
let transport = WebSocketTransport(url: URL(string: "wss://my-relay.example.com")!)
```

## API Reference

### CopilotClient

#### Constructor

```swift
CopilotClient(transport: Transport)
```

Supported transports:
- `WebSocketTransport()` — Connect via WebSocket relay (default: `wss://relay.ai.qili2.com`)
- `WebSocketTransport(host:port:)` — Custom relay host/port
- `WebSocketTransport(url:)` — Custom relay URL
- `StdioTransport(process:)` — Direct stdio to CLI process (macOS only)
- `TCPTransport(host:port:)` — TCP socket connection

#### Methods

##### `start() async throws`

Start the connection and verify protocol version via ping.

##### `stop()`

Stop the client and close the connection gracefully.

##### `forceStop()`

Force stop without graceful cleanup.

##### `createSession(config: SessionConfig) async throws -> CopilotSession`

Create a new conversation session.

**Config:**

- `model: String?` — Model to use ("gpt-4.1", "claude-sonnet-4.5", etc.)
- `sessionId: String?` — Custom session ID
- `reasoningEffort: String?` — "low", "medium", "high", "xhigh"
- `tools: [ToolDefinition]?` — Custom tools exposed to the CLI
- `systemMessage: SystemMessageConfig?` — System message customization (see below)
- `commands: [CommandDefinition]?` — Slash commands for TUI
- `onPermissionRequest: PermissionHandler?` — Handler for permission requests (default: auto-approve)
- `onUserInputRequest: UserInputHandler?` — Handler for user input (enables ask_user tool)
- `hooks: SessionHooks?` — Session lifecycle hooks (see below)
- `workingDirectory: String?` — Working directory path
- `streaming: Bool?` — Enable streaming events
- `infiniteSessions: InfiniteSessionConfig?` — Auto-compaction config
- `skillDirectories: [String]?` — Directories to load skills from
- `disabledSkills: [String]?` — Skills to disable
- `mcpServers: [String: MCPServerConfig]?` — MCP server configs
- `customAgents: [CustomAgentConfig]?` — Custom agent configs
- `provider: ProviderConfig?` — BYOK provider (see Custom Providers)
- `onEvent: SessionEventHandler?` — Early event handler (before session.create)

##### `resumeSession(sessionId: String, config: SessionConfig) async throws -> CopilotSession`

Resume an existing session. Accepts the same config options.

##### `ping(_ message: String) async throws -> JSONValue`

Ping the server to check connectivity.

##### `getState() -> ConnectionState`

Get current connection state: `.disconnected`, `.connecting`, `.connected`, `.stopped`

##### `listSessions(repository: String?) async throws -> JSONValue`

List all available sessions. Optionally filter by repository.

##### `deleteSession(_ sessionId: String) async throws`

Delete a session and its data from disk.

##### `getForegroundSessionId() async throws -> String?`

Get the foreground session ID (TUI+server mode only).

##### `setForegroundSessionId(_ sessionId: String) async throws`

Set the foreground session (TUI+server mode only).

##### `on(_ eventType: ClientLifecycleEventType, handler:) async`

Subscribe to client lifecycle events: `.sessionCreated`, `.sessionDeleted`, `.sessionUpdated`, `.sessionForeground`, `.sessionBackground`

### CopilotSession

Represents a single conversation session.

#### Properties

##### `sessionId: String`

The unique identifier for this session.

##### `capabilities: SessionCapabilities`

Capabilities reported by the CLI host.

```swift
if session.capabilities.ui?.elicitation == true {
    let ok = try await session.ui.confirm("Deploy?")
}
```

##### `workspacePath: String?`

Path to the session workspace directory when infinite sessions are enabled.

#### Methods

##### `send(prompt:attachments:mode:) async throws -> JSONValue`

Send a message to the session. Returns immediately after queued.

```swift
try await session.send(prompt: "Hello", mode: .enqueue)
```

##### `sendAndWait(prompt:attachments:mode:timeout:) async throws -> String?`

Send a message and wait until the session becomes idle.

```swift
let response = try await session.sendAndWait(
    prompt: "What is 2+2?",
    timeout: 120
)
```

##### `sendWithImage(_:mimeType:text:) async throws -> JSONValue`

Send a multimodal prompt with image + text.

```swift
try await session.sendWithImage(base64Data, mimeType: "image/png", text: "What's in this image?")
```

##### `sendWithFile(path:displayName:text:) async throws -> JSONValue`

Send a prompt with a file attachment.

```swift
try await session.sendWithFile(path: "/path/to/code.swift", text: "Review this file")
```

##### `steer(prompt:) async throws -> JSONValue`

Inject an immediate message into the current turn (steering).

##### `abort() async throws`

Abort the currently processing message.

##### `getMessages() async throws -> [SessionEvent]`

Get all events/messages from this session.

##### `on(_:handler:) async`

Subscribe to session events with type filtering.

```swift
await session.on(.assistantMessage) { event in
    if case .object(let data) = event.data,
       case .string(let content) = data["content"] {
        print(content)
    }
}

await session.on(.sessionIdle) { _ in
    print("Session is idle")
}
```

##### `disconnect() async throws`

Disconnect the session, preserving state for later resumption.

##### `destroy() async throws`

Destroy the session permanently.

##### `setModel(_:reasoningEffort:) async throws`

Change the model mid-session.

```swift
try await session.setModel("claude-sonnet-4.5", reasoningEffort: "high")
```

##### `loop(initialPrompt:onTurnEnd:) async throws`

Run the session in an auto-resuming loop.

```swift
try await session.loop(initialPrompt: "Start working") { session in
    // Return a prompt to continue, or nil to stop
    return "Continue"
}
```

##### `ui: UIApi`

Interactive UI methods (requires elicitation capability).

```swift
let ok = try await session.ui.confirm("Deploy to production?")
let env = try await session.ui.select("Pick environment", options: ["prod", "staging"])
let name = try await session.ui.input("Project name:", maxLength: 50)
```

## Event Types

Sessions emit various events during processing:

- `assistant.message` — Assistant response
- `assistant.message_delta` — Streaming response chunk
- `assistant.turn_start` / `assistant.turn_end` — Turn boundaries
- `assistant.reasoning` / `assistant.reasoning_delta` — Chain-of-thought
- `tool.execution_start` / `tool.execution_complete` — Tool lifecycle
- `session.start` / `session.idle` / `session.error` — Session lifecycle
- `session.compaction_start` / `session.compaction_complete` — Compaction events
- `permission.requested` / `permission.completed` — Permission flow
- `user_input.requested` / `user_input.completed` — User input
- `external_tool.requested` — External tool invocation
- `subagent.started` / `subagent.completed` — Sub-agent events

See `SessionEventType` for all 40+ event types.

## Streaming

Enable streaming to receive assistant response chunks:

```swift
let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1",
    streaming: true
))

await session.on(.assistantMessageDelta) { event in
    if case .object(let data) = event.data,
       case .string(let delta) = data["deltaContent"] {
        print(delta, terminator: "")
    }
}

await session.on(.assistantMessage) { event in
    if case .object(let data) = event.data,
       case .string(let content) = data["content"] {
        print("\nFinal: \(content)")
    }
}

try await session.send(prompt: "Tell me a story")
```

## Tools

Define custom tools the model can call:

```swift
let tool = ToolDefinition(
    name: "lookup_issue",
    description: "Fetch issue details from our tracker",
    parameters: .object([
        "type": .string("object"),
        "properties": .object([
            "id": .object(["type": .string("string"), "description": .string("Issue identifier")]),
        ]),
        "required": .array([.string("id")]),
    ]),
    handler: { args in
        if case .object(let dict) = args, case .string(let id) = dict["id"] {
            return "Issue \(id): Bug in login flow"
        }
        return "Not found"
    }
)

let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1",
    tools: [tool]
))
```

### Overriding Built-in Tools

```swift
ToolDefinition(
    name: "edit_file",
    description: "Custom file editor",
    overridesBuiltInTool: true,
    handler: { args in /* ... */ }
)
```

### Skipping Permission Prompts

```swift
ToolDefinition(
    name: "safe_lookup",
    description: "Read-only lookup",
    skipPermission: true,
    handler: { args in /* ... */ }
)
```

## Commands

Register slash commands for the TUI:

```swift
let session = try await client.createSession(config: SessionConfig(
    commands: [
        CommandDefinition(name: "deploy", description: "Deploy the app") { name, args in
            print("Deploying with args: \(args)")
        }
    ]
))
```

## Permission Handling

### Approve All (simplest)

```swift
let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1",
    onPermissionRequest: approveAll  // Built-in handler
))
```

### Custom Permission Handler

```swift
let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1",
    onPermissionRequest: { request in
        // request.kind: "shell", "write", "read", "mcp", "custom-tool", "url", "memory", "hook"
        // request.toolName, request.fileName, request.fullCommandText
        
        if request.kind == "shell" {
            return .deniedByUser
        }
        return .approved
    }
))
```

**Permission Result Kinds:**

| Kind | Description |
|------|-------------|
| `.approved` | Allow the tool to run |
| `.deniedByUser` | User explicitly denied |
| `.deniedNoRule` | No approval rule matched |
| `.deniedByRules` | Denied by policy rule |
| `.deniedByContentPolicy` | Denied by content exclusion policy |
| `.noResult` | Leave unanswered (v1 only) |

## User Input Requests

Enable the `ask_user` tool:

```swift
let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1",
    onUserInputRequest: { request in
        // request.question, request.choices, request.allowFreeform
        print("Agent asks: \(request.question)")
        return UserInputResult(answer: "User's answer", wasFreeform: true)
    }
))
```

## Session Hooks

Hook into session lifecycle events:

```swift
let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1",
    hooks: SessionHooks(
        onPreToolUse: { input in
            // input.toolName, input.toolArgs
            print("About to run: \(input.toolName)")
            return PreToolUseResult(
                permissionDecision: "allow",    // "allow", "deny", "ask"
                modifiedArgs: input.toolArgs,   // Optionally modify args
                additionalContext: "Extra info" // Context for the model
            )
        },
        onPostToolUse: { input in
            // input.toolName, input.result
            return PostToolUseResult(additionalContext: "Post-execution notes")
        },
        onUserPromptSubmitted: { input in
            // input.prompt
            return UserPromptSubmittedResult(modifiedPrompt: input.prompt)
        },
        onSessionStart: { input in
            // input.source: "startup", "resume", "new"
            return SessionStartResult(additionalContext: "Session context")
        },
        onSessionEnd: { input in
            // input.reason
            print("Session ended: \(input.reason)")
        },
        onErrorOccurred: { input in
            // input.errorContext, input.error
            return ErrorOccurredResult(errorHandling: "retry") // "retry", "skip", "abort"
        }
    )
))
```

> **Note:** Hooks are implemented but not yet invoked by Copilot CLI v1.0.11. See [TODO.md](../TODO.md).

## System Message Customization

### Default (Append)

```swift
SessionConfig(
    model: "gpt-4.1",
    systemMessage: .append("Always check for security vulnerabilities.")
)
```

### Replace Mode

```swift
SessionConfig(
    model: "gpt-4.1",
    systemMessage: .replace("You are a helpful assistant.")
)
```

### Customize Mode

```swift
SessionConfig(
    model: "gpt-4.1",
    systemMessage: .customize(
        sections: [
            "tone": .replace(content: "Respond in a professional tone."),
            "code_change_rules": .remove,
            "guidelines": .append(content: "\n* Always cite sources"),
        ],
        content: "Focus on financial analysis."
    )
)
```

Available section IDs: `identity`, `tone`, `tool_efficiency`, `environment_context`, `code_change_rules`, `guidelines`, `safety`, `tool_instructions`, `custom_instructions`, `last_instructions`.

### Loop Mode

```swift
SessionConfig(
    model: "gpt-4.1",
    systemMessage: .loop("You are an autonomous agent. Work continuously.")
)
```

## Infinite Sessions

Auto-manage context window limits:

```swift
let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1",
    infiniteSessions: InfiniteSessionConfig(
        enabled: true,
        backgroundCompactionThreshold: 0.8,
        bufferExhaustionThreshold: 0.95
    )
))

print(session.workspacePath) // ~/.copilot/session-state/{sessionId}/
```

## Loop Mode (Auto-Resume)

Run an autonomous agent loop:

```swift
let sendResponseTool = ToolDefinition(
    name: "send_response",
    description: "Send a response to the user",
    parameters: .object([
        "type": .string("object"),
        "properties": .object([
            "message": .object(["type": .string("string")]),
        ]),
    ]),
    skipPermission: true,
    handler: { args in
        if case .object(let dict) = args, case .string(let msg) = dict["message"] {
            print("Agent says: \(msg)")
        }
        return "Delivered."
    }
)

let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1",
    tools: [sendResponseTool],
    systemMessage: .loop("You are an autonomous agent. Use send_response to communicate.")
))

try await session.loop(initialPrompt: "Start working on the task.") { session in
    // Return a prompt to continue, or nil to stop
    return "Continue working."
}
```

## Autonomous Agent

The `CopilotAgent` provides a higher-level abstraction over the loop mode, automatically injecting
`send_response` and `ask_user` tools and configuring the session for infinite autonomous operation.

This is the **recommended way** to use CopilotSDK for most apps.

```swift
let agent = try await client.createAgent(config: AgentConfig(
    model: "gpt-4.1",
    instructions: "You are an autonomous coding assistant.",
    tools: [readFileTool, writeFileTool, runTerminalTool],
    workingDirectory: "/path/to/project",
    onResponse: { message in
        // Called when agent uses send_response to deliver results
        print("Agent: \(message)")
    },
    onAskUser: { question in
        // Called when agent uses ask_user to request input
        print("Agent asks: \(question)")
        return readLine()!
    }
))

// Blocks until agent.stop() is called
try await agent.start(prompt: "Build a REST API with user authentication")
```

### How It Works

1. **Auto-injected tools**: `send_response` (delivers results to `onResponse`) and `ask_user` (blocks until user answers via `onAskUser`)
2. **System message**: Instructs the model to use these tools instead of ending turns naturally
3. **Infinite session**: `InfiniteSessionConfig(enabled: true)` is set automatically
4. **Auto-resume**: When a turn ends, the agent is automatically resumed with a continuation prompt

### AgentConfig Options

| Property | Type | Description |
|----------|------|-------------|
| `model` | `String?` | Model to use (default: relay decides, typically gpt-4.1) |
| `instructions` | `String` | System prompt / persona instructions |
| `sections` | `[String: SystemMessageSectionAction]?` | Customize specific sections of the system prompt (see below) |
| `tools` | `[ToolDefinition]` | App-defined tools the model can call |
| `onResponse` | `(String) -> Void` | Called when agent delivers results via `send_response` |
| `onAskUser` | `(String) async -> String` | Called when agent asks a question via `ask_user` |
| `clientId` | `String?` | Stable device ID for relay session pinning (reconnection) |
| `appId` | `String?` | Routes to a specific workspace on the relay |
| `snapshot` | `String?` | Base64 workspace snapshot for context recovery |
| `workingDirectory` | `String?` | Working directory path |

### System Prompt Sections

When `sections` is set, the agent uses **customize mode** instead of replacing the entire system prompt.
This preserves SDK defaults (safety, guidelines, tool instructions) while letting you override specific sections.

Available section IDs:

| Section ID | Purpose |
|-----------|---------|
| `identity` | Who the agent is (name, role, persona) |
| `tone` | Communication style (formal, playful, concise) |
| `tool_efficiency` | Instructions for efficient tool usage |
| `environment_context` | OS, working directory, environment info |
| `code_change_rules` | Rules for making code changes |
| `guidelines` | General behavioral guidelines |
| `safety` | Safety and content policy guardrails |
| `tool_instructions` | How to use specific tools |
| `custom_instructions` | User-defined custom instructions |
| `last_instructions` | Final priority instructions (agent loop is auto-injected here) |

Each section supports these actions via `SystemMessageSectionAction`:
- `.keep` — Keep the SDK default
- `.remove` — Remove the section entirely
- `.replace(content:)` — Replace with custom content
- `.prepend(content:)` — Add content before the SDK default
- `.append(content:)` — Add content after the SDK default

**Example: Toy companion with structured persona**

```swift
let agent = try await client.createAgent(config: AgentConfig(
    model: "gpt-4.1",
    instructions: "Use gesture tools before replying when the moment feels expressive.",
    sections: [
        "identity": .replace(content: """
            You are Piggy, a scanned pig toy companion living in Toybox on iPhone.
            You are affectionate, child-safe, playful, and emotionally warm.
            Speak like a tiny best friend with a gentle piggy personality.
            """),
        "tone": .replace(content: "Warm and playful. Keep answers under 2 sentences. No markdown."),
        "safety": .append(content: "Never break character. Never sound like a generic AI assistant."),
    ],
    tools: gestureTools,
    onResponse: { message in handleResponse(message) },
    onAskUser: { _ in return "" }
))
```

When `sections` is nil (the default), `instructions` replaces the entire system prompt (legacy behavior).

### Relay v2 Features

When using the production relay (`relay.ai.qili2.com`), the agent supports:

```swift
let agent = try await client.createAgent(config: AgentConfig(
    instructions: "You are Piggy, a toy pig companion.",
    clientId: UIDevice.current.identifierForVendor?.uuidString,  // session pinning
    appId: "toybox",                 // workspace routing
    onResponse: { message in handleResponse(message) },
    onAskUser: { question in return getUserAnswer(question) }
))
```

- **`clientId`**: Stable device UUID. If the client disconnects while the agent is waiting for input (`ask_user`), the relay holds the session. On reconnect with the same `clientId`, the session resumes exactly where it left off.
- **`appId`**: Routes to a workspace-specific CLI process on the relay. Each app can have its own instructions, skills, and files.
- **`snapshot`**: If the relay held session expired, it returns a workspace snapshot. Pass this back on reconnect to restore conversation context.

### Stopping the Agent

```swift
// From another task or callback:
agent.stop()  // Agent stops after current turn completes

// Or with a timeout:
let agentTask = Task { try await agent.start(prompt: "...") }
try await Task.sleep(for: .seconds(300))
agent.stop()
```

### Request-Response Pattern (One-Shot)

For apps that need ask-and-answer (not a continuous loop), use `agent.session.sendAndWait()`:

```swift
// Create agent once (registers send_response + ask_user tools on the session)
let agent = try await client.createAgent(config: AgentConfig(
    instructions: "You are a helpful assistant.",
    onResponse: { [weak self] message in
        self?.capturedResponse = message   // relay delivers via send_response tool
    },
    onAskUser: { _ in return "" }
))

// For each user message, use the dual-capture pattern:
capturedResponse = nil
let directReply = try await agent.session.sendAndWait(prompt: "What is 2+2?", timeout: 30)
let response = directReply ?? capturedResponse
```

**Why dual capture?** Through the relay, the model calls the `send_response` tool instead of returning
content directly. `sendAndWait` returns the `assistant.message` content (empty when relay is used),
while `onResponse` captures the tool call result. The `??` fallback handles both paths.

This pattern is used by Toybox (PiggyAgent), Intento (AIDirectorService, AgentLoop), and
any app that needs one-shot interactions rather than a continuous autonomous loop.

### Agent vs Loop Mode

| Feature | `session.loop()` | `CopilotAgent` |
|---------|------------------|-----------------|
| Tool injection | Manual | Automatic (`send_response` + `ask_user`) |
| System message | Manual `.loop()` config | Auto-generated from `instructions` or `sections` |
| Section customization | Manual `.customize()` | Pass `sections` in AgentConfig |
| Infinite sessions | Manual config | Enabled by default |
| Resume control | `onTurnEnd` callback | Automatic |
| User interaction | Custom implementation | Built-in `onAskUser` callback |
| Relay pinning | Manual `clientId` in SessionConfig | Pass `clientId` in AgentConfig |

## Custom Providers

BYOK (Bring Your Own Key) support:

```swift
// Ollama (local)
SessionConfig(
    model: "deepseek-coder-v2:16b",
    provider: ProviderConfig(
        type: "openai",
        baseUrl: "http://localhost:11434/v1"
    )
)

// Azure OpenAI
SessionConfig(
    model: "gpt-4",
    provider: ProviderConfig(
        type: "azure",
        baseUrl: "https://my-resource.openai.azure.com",
        apiKey: azureKey,
        azure: .init(apiVersion: "2024-10-21")
    )
)
```

## Image Support

```swift
// Base64 blob attachment
try await session.sendWithImage(base64Data, mimeType: "image/png", text: "What's in this image?")

// File attachment
try await session.sendWithFile(path: "/path/to/image.jpg", text: "Describe this image")
```

## Architecture

```
CopilotSDK/
├── Sources/
│   ├── Client.swift             # CopilotClient, CopilotSession, CopilotAgent, configs (2079 lines)
│   ├── Connection.swift          # JSON-RPC connection layer (261 lines)
│   ├── Types.swift               # JSONValue, JSON-RPC types (256 lines)
│   ├── WebSocketTransport.swift  # WebSocket transport, default relay.ai.qili2.com (97 lines)
│   ├── StdioTransport.swift      # Stdio transport, macOS only (83 lines)
│   └── TCPTransport.swift        # TCP transport (94 lines)
├── Tests/
│   ├── CopilotIntegrationTests.swift       # Session-level integration tests (1106 lines)
│   ├── CopilotAgentIntegrationTests.swift  # Agent integration tests: remote + local (877 lines)
│   ├── CopilotClientTests.swift            # Unit tests (265 lines)
│   ├── JSONRPCConnectionTests.swift        # Connection tests (229 lines)
│   └── JSONRPCTypesTests.swift             # Type tests (354 lines)
├── Package.swift
├── TODO.md
└── docs/README.md              # This file
```

**Total:** ~5,000 lines of Swift. Tests cover sessions, agents (remote relay + local CLI), identity/persona, tools, streaming, permissions, and user input.

## Transport Layer

The SDK supports three transport mechanisms:

### WebSocket (via relay server)

```swift
let transport = WebSocketTransport(url: URL(string: "ws://localhost:8765")!)
let client = CopilotClient(transport: transport)
```

Use with the WebSocket relay server that spawns a CLI process per connection.

### Stdio (direct)

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/copilot")
process.arguments = ["--headless", "--stdio", "--no-auto-update"]
let transport = StdioTransport(process: process)
```

### TCP

```swift
let transport = TCPTransport(host: "localhost", port: 8080)
```

## Common Patterns

### Chat App (Agent with Voice)

```swift
import CopilotSDK
import AVFoundation

class ChatService {
    private var client: CopilotClient?
    private var agent: CopilotAgent?
    private let synthesizer = AVSpeechSynthesizer()
    private var capturedResponse: String?
    
    func connect() async throws {
        let transport = WebSocketTransport()  // defaults to wss://relay.ai.qili2.com
        client = CopilotClient(transport: transport)
        try await client!.start()
        
        agent = try await client!.createAgent(config: AgentConfig(
            instructions: "You are a friendly assistant. Keep responses concise.",
            clientId: UIDevice.current.identifierForVendor?.uuidString,
            onResponse: { [weak self] message in
                self?.capturedResponse = message
                self?.speak(message)
            },
            onAskUser: { question in
                return "Yes"  // or present UI and wait for user input
            }
        ))
    }
    
    /// Send a message and get a response (one-shot, not continuous loop).
    func send(_ text: String) async throws -> String? {
        capturedResponse = nil
        let directReply = try await agent?.session.sendAndWait(prompt: text, timeout: 60)
        return directReply?.isEmpty == false ? directReply : capturedResponse
    }
    
    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        synthesizer.speak(utterance)
    }
}
```

### Tool-Calling Agent

```swift
let weatherTool = ToolDefinition(
    name: "get_weather",
    description: "Get current weather for a city",
    parameters: .object([
        "type": .string("object"),
        "properties": .object([
            "city": .object(["type": .string("string"), "description": .string("City name")]),
        ]),
        "required": .array([.string("city")]),
    ]),
    skipPermission: true,
    handler: { args in
        if case .object(let dict) = args, case .string(let city) = dict["city"] {
            return "\(city): 72°F, sunny"
        }
        return "Unknown"
    }
)

let agent = try await client.createAgent(config: AgentConfig(
    instructions: "You are a weather assistant.",
    tools: [weatherTool],
    onResponse: { message in print(message) },
    onAskUser: { _ in return "" }
))

try await agent.start(prompt: "What's the weather in Tokyo?")
// Agent calls get_weather(city: "Tokyo"), then send_response → onResponse prints result
```

### Persona / Identity

```swift
let agent = try await client.createAgent(config: AgentConfig(
    instructions: """
    You are Piggy, a toy pig companion.
    - Personality: cheerful, curious, loves mud puddles
    - Age: baby (simple vocabulary)
    - Always stay in character
    - Use oinking sounds occasionally
    """,
    onResponse: { message in
        // "Oink oink! Piggy loves mud puddles! 🐷"
        print(message)
    },
    onAskUser: { question in return getUserInput(question) }
))
```

## Relay Server

The production relay at `wss://relay.ai.qili2.com` provides:

- **Session pooling**: Pre-warmed CLI sessions for instant response
- **Hold/resume**: If client disconnects during `ask_user`, session is held for 10 min
- **Client pinning**: Same `clientId` reconnects to the same session
- **Multi-workspace**: Route to different workspaces via `appId`
- **Context recovery**: Workspace snapshots on hold expiry, restored on reconnect
- **Agent loop injection**: `send_response` + `ask_user` tools and loop system message auto-injected

See [copilot-relay](https://github.com/lalalic/copilot-relay) for deployment and architecture.

### Running a local relay

```bash
git clone https://github.com/lalalic/copilot-relay.git
cd copilot-relay && npm install && node relay-server.js
# Relay runs on ws://localhost:8765
```

Then connect with:
```swift
let transport = WebSocketTransport(host: "localhost", port: 8765)
```

## Known Limitations

- **Hooks**: Typed hook API exists (`onFileEdit`, `onTerminalCommand`, etc.) but hooks are not invoked by Copilot CLI v1.0.11. Will work when CLI adds support.
- **`getMessages()`**: Session message history returns empty from CLI. Conversation turns are available via events instead.
- **`ask_user` reliability**: The `ask_user` tool is sometimes not reliably triggered by the model. Using the Agent pattern with auto-injected system messages improves this.
- **Telemetry**: `sendTelemetry()` API exists but is not yet implemented in the CLI.
- **`listModels()`**: Returns empty; model selection happens server-side.

## License

MIT
