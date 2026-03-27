# WebKitAgent — Design & Implementation

## Concept
A minimal Swift package that gives AI agents browser capabilities via WKWebView.
Like `agent-browser` but native iOS/macOS, lightweight, and embeddable as a single tool.

## Architecture

```
┌─────────────────────────────────────────┐
│           AI Agent (CopilotAgent)       │
│  "download BGM from freesound.org"      │
└────────────┬────────────────────────────┘
             │ tool call: web_agent
             │ {command: "navigate", url: "..."}
┌────────────▼────────────────────────────┐
│         WebKitAgent (Package)           │
│                                         │
│  Single Tool: web_agent                 │
│  Sub-commands:                          │
│  ├── navigate  → load page, wait       │
│  ├── snapshot  → DOM→refs (r0,r1...)   │
│  ├── click     → tap element by ref    │
│  ├── type      → fill input by ref     │
│  ├── download  → save file (ref/URL)   │
│  └── upload    → upload file to input  │
│                                         │
│  + skillPrompt for LLM sub-command docs │
│                                         │
│  Core:                                  │
│  ├── WebViewManager    → WKWebView      │
│  ├── DOMSnapshot       → JS scripts    │
│  └── WebAgentView      → SwiftUI embed  │
└─────────────────────────────────────────┘
```

## Key Design: Single Tool + Sub-commands

Instead of 6 separate tools, WebKitAgent exposes ONE tool (`web_agent`) with a `command` parameter.
The LLM learns sub-commands via `WebAgentToolProvider.skillPrompt` appended to the system prompt.

**Why single tool?**
- Reduces tool count in agent context (LLMs handle fewer tools better)
- All params share one flat schema — simpler for function calling
- Skill prompt gives richer documentation than split tool descriptions

## Ref System: `data-wa-ref`

Each `snapshot` call:
1. Removes all existing `data-wa-ref` attributes (clean slate)
2. Scans for interactive elements (links, buttons, inputs, selectors, ARIA roles)
3. Filters hidden/zero-size elements
4. Assigns sequential refs: `r0`, `r1`, `r2`, ...
5. Returns text listing: `r0 [button] "Sign In"`, `r1 [input type=text] placeholder="Email"`

Subsequent `click`, `type`, `download` use refs directly via `querySelector('[data-wa-ref="r5"]')`.

**Element selectors scanned:**
```
a[href], button, input, textarea, select,
[role="button"], [role="link"], [role="tab"],
[role="menuitem"], [role="checkbox"], [role="radio"],
[role="switch"], [role="option"], [role="textbox"],
[onclick], [tabindex], summary, label[for], details,
video, audio
```

## Download Strategy

Cookie-aware URLSession download:
1. Extract href from element by ref (or use direct URL)
2. Copy all WKWebView cookies to URLSession request
3. Set Referer header from current page
4. Download via `URLSession.shared.data(for:)`
5. Save to `Documents/WebKitAgent/` directory

## Upload Strategy

WKUIDelegate file picker interception:
1. Pre-load file URL in `pendingUploadURLs`
2. Click the `<input type="file">` element
3. `WKUIDelegate.runOpenPanelWith` returns the pre-loaded URLs (macOS)
4. On iOS, the file input `click()` is handled natively

## Package Structure (Implemented)
```
WebKitAgent/
├── Package.swift                — Swift 6.0, iOS 17+, macOS 15+
├── Sources/
│   ├── WebViewManager.swift     — WKWebView lifecycle, all operations
│   ├── DOMSnapshot.swift        — JS scripts (snapshot, click, type)
│   ├── WebAgentToolProvider.swift — Single web_agent tool + skillPrompt
│   └── WebAgentView.swift       — SwiftUI wrapper (iOS/macOS)
├── Tests/
│   ├── DOMSnapshotTests.swift   — 22 tests: script structure, selectors, refs
│   ├── WebAgentToolProviderTests.swift — 18 tests: tool schema, dispatch, errors
│   ├── WebViewManagerTests.swift — 10 tests: init, state, delegates
│   └── (WebAgentErrorTests)     — 5 tests: error descriptions
└── docs/
    └── design.md                — this file
```

## Integration

```swift
import WebKitAgent
import CopilotSDK

let manager = WebViewManager()
let webTools = WebAgentToolProvider(manager: manager)

let agent = CopilotAgent(config: AgentConfig(
    model: "gpt-4.1",
    instructions: "You are a web assistant.\n" + WebAgentToolProvider.skillPrompt,
    tools: webTools.tools
))
```

With CameraKit:
```swift
let allTools = cameraTools.compactTools + webTools.tools
```

## Use Cases

### 1. Auto-download BGM
```
web_agent(command: "navigate", url: "https://freesound.org")
web_agent(command: "snapshot")
  → r0 [input] placeholder="Search sounds"
  → r1 [button] "Search"
web_agent(command: "type", ref: "r0", text: "cinematic background")
web_agent(command: "click", ref: "r1")
web_agent(command: "snapshot")
  → r0 [a] "Ocean Waves" → /sounds/123/
web_agent(command: "download", ref: "r0")
  → Downloaded: ocean-waves.mp3 (2.4 MB) → .../WebKitAgent/ocean-waves.mp3
```

### 2. Auto-post to social
```
web_agent(command: "navigate", url: "https://social.example/compose")
web_agent(command: "snapshot")
  → r0 [textarea] placeholder="What's on your mind?"
  → r3 [button] "Post"
web_agent(command: "type", ref: "r0", text: "Check out my new film! 🎬")
web_agent(command: "click", ref: "r3")
```

## Test Coverage: 55 tests
- **DOMSnapshot** (22): IIFE structure, selector coverage, ref attributes, ARIA roles, visibility checks, click/type escaping, JSON output
- **ToolProvider** (18): Single tool schema, command enum, required params, skill prompt content, error dispatch for all commands
- **WebViewManager** (10): WebView creation, delegates, frame size, download dir, initial state
- **WebAgentError** (5): All error type descriptions
