# CopilotChat

A shared SwiftUI chat UI for CopilotSDK. One UI for both session mode and autonomous (agent) mode — the difference is only at the protocol layer (`send_response` tool injection), not the UI.

## User Interaction Model

Three scenarios, identical for both modes. Each supports **text**, **speech**, and **attachment**.

### 1. User sends a prompt
User types/speaks a message → sends it. In session mode this happens frequently (back-and-forth). In autonomous mode this is typically the initial prompt and occasional follow-ups.

### 2. ask_user — waiting for user input
The model calls `ask_user` to request input. The UI indicates it's waiting. User responds via text, speech, or attachment. This is the same in both modes.

### 3. Steer — inject context during tool calling
While the model is executing tools, the user can send a steer message to redirect or add context. Works the same in both modes.

## Architecture

```
CopilotChat (SwiftUI views + view model)
  └── depends on: CopilotSDK

Session mode:  CopilotClient → CopilotSession → events → ChatViewModel → ChatView
Agent mode:    CopilotClient → CopilotAgent (session + send_response) → ChatViewModel → ChatView
```

**One ChatViewModel** handles both modes. Agent mode adds `send_response` + `ask_user` tools via `CopilotAgent`, but the UI layer doesn't care — it just renders messages and handles user input.

## Components

| View | Purpose |
|------|---------|
| `ChatView` | Full chat window: message list + todo panel + input bar |
| `MessageBubble` | Single message — avatar, markdown content, tool indicators |
| `MarkdownView` | Renders markdown (headings, bold, code, tables, lists) |
| `MermaidView` | Renders mermaid code blocks as inline SVG via mermaid.js |
| `TodoPanelView` | Task list above input bar (from `manage_todo_list` tool) |
| `InputBar` | Multi-mode input: text field + mic + attachment + send |
| `ToolActivityView` | Inline tool call status indicators |

## Input Bar States

Configurable input modes via `ChatView.inputModes` — enable any combination:

```swift
ChatView(viewModel: chat, inputModes: [.text, .speech])        // both (default)
ChatView(viewModel: chat, inputModes: [.text])                 // text only
ChatView(viewModel: chat, inputModes: [.speech])               // speech only
ChatView(viewModel: chat, inputModes: [.text, .speech, .attachment]) // all
```

```
┌───────────────────────────────────────────────────┐
│ Text+Speech: [📎] [Type a message...      ] [🎤] │  ← default
│ Text only:         [Type a message...      ] [➤] │
│ Speech only:       [     🎤 Tap to speak        ] │
│ Waiting:     [📎] [Reply...               ] [🎤] │  ← ask_user pending (pulsing)
│ Working:     [📎] [Steer...               ] [🎤] │  ← tools running (can steer)
│ Listening:   [📎] [ 🔴 Listening...       ] [⏹] │  ← speech active
└───────────────────────────────────────────────────┘
```

## Message Types

| Content | Rendering |
|---------|-----------|
| Plain text | `Text` |
| Markdown | `AttributedString(markdown:)` + custom code blocks |
| Code blocks | Monospace font, syntax highlighting, copy button |
| Mermaid (```mermaid) | Inline SVG via WKWebView + mermaid.js |
| Images | Inline image view |
| Attachments | File chip with name + icon |
| Tool calls | Collapsible status row (⚙️ name → ✓ result) |
| Todo list | Dedicated panel above input bar |

## Quick Start

```swift
import CopilotChat
import CopilotSDK

// Agent mode (autonomous)
let chat = ChatViewModel(
    transport: WebSocketTransport(host: "10.0.0.111", port: 8765),
    mode: .agent(AgentConfig(
        instructions: "",
        tools: myTools,
        appId: "intento",
        onResponse: { _ in },
        onAskUser: { _ in "" }
    ))
)

// Session mode (interactive)
let chat = ChatViewModel(
    transport: WebSocketTransport(host: "10.0.0.111", port: 8765),
    mode: .session(SessionConfig(model: "gpt-4o"))
)

// Same view for both
ChatView(viewModel: chat)
```

## Requirements

- iOS 18.0+ / macOS 15.0+
- Swift 6.0+
- CopilotSDK

## Structured Questions (`ask_questions`)

CopilotChat now supports the `ask_questions` tool with the same schema as VS Code:
- **Multiple choice options** (single-select or multi-select)
- **Recommended option** highlighting
- **Free-form text input** alongside options
- **Multiple questions** in a single call (batch up to 4)
- **Headers** for each question

The `ask_questions` schema:

```json
{
  "questions": [{
    "header": "Short Label",
    "question": "Full question text",
    "options": [
      { "label": "Option A", "description": "...", "recommended": true },
      { "label": "Option B" }
    ],
    "multiSelect": false,
    "allowFreeformInput": false
  }]
}
```

Responses are returned as a structured object keyed by question header:

```json
{
  "Header": {
    "selected": ["Option A"],
    "freeText": "optional notes",
    "skipped": false
  }
}
```
