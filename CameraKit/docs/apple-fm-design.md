# Apple Foundation Models Integration Design

## Overview

CameraKit currently uses **CopilotSDK** (GitHub Copilot cloud API) as the LLM backend.
Apple's **Foundation Models** framework (iOS 26+) provides on-device LLM with native tool calling.

This design enables CameraKit to work with **both backends** — cloud for power, on-device for privacy/speed.

## Architecture

```
┌─────────────────────────────────────────┐
│           CameraKit Services            │
│  CameraService · SceneAnalyzer · Voice  │
│         (Backend-agnostic)              │
└──────────────┬──────────────────────────┘
               │
       ┌───────┴───────┐
       ▼               ▼
┌──────────────┐ ┌──────────────────┐
│ CopilotSDK   │ │ Apple Foundation │
│ ToolProvider  │ │ Models Tools     │
│ (24 tools)   │ │ (compact: ~5)    │
│              │ │                  │
│ ToolDefinition│ │ Tool protocol    │
│ JSON params  │ │ @Generable args  │
│ String output│ │ PromptRepresentable│
└──────┬───────┘ └────────┬─────────┘
       │                  │
       ▼                  ▼
  CopilotClient    LanguageModelSession
  (WebSocket/API)  (on-device, private)
```

## Key Differences

| Feature | CopilotSDK | Apple Foundation Models |
|---------|-----------|------------------------|
| **Model** | GPT-4o / Claude (cloud) | Apple on-device LLM |
| **Tools** | `ToolDefinition` (JSON schema) | `Tool` protocol (`@Generable` args) |
| **Output** | String | `PromptRepresentable` (String or `@Generable`) |
| **Context** | Large (128k+) | Small (requires careful management) |
| **Recommended tools** | 10-30 | 3-5 max |
| **Auth** | GitHub token | None (on-device) |
| **Latency** | Network dependent | ~instant |
| **Privacy** | Data leaves device | 100% on-device |
| **Min OS** | iOS 16+ | iOS 26+ |

## Strategy: Compact Tools for Apple FM

Apple recommends **3-5 tools**. Our compact mode (13 tools) is still too many.
For Apple FM, create an **ultra-compact** mode with ~5 tools:

1. **`camera_action`** — unified camera control (configure + record + photo)
2. **`analyze_frame`** — unified vision (scene + faces + composition + quality)
3. **`speak`** — TTS output
4. **`listen`** — speech input
5. **`wait`** — timing control

## Tool Protocol Mapping

```swift
// Apple's Tool protocol
protocol Tool<Arguments, Output> {
    var name: String { get }
    var description: String { get }
    associatedtype Arguments: ConvertibleFromGeneratedContent
    associatedtype Output: PromptRepresentable
    func call(arguments: Arguments) async throws -> Output
}

// Example: observe camera as Apple FM Tool
struct ObserveCameraTool: Tool {
    let name = "observe_camera"
    let description = "Look through the camera"
    
    @Generable struct Arguments {} // no args
    
    let camera: CameraService
    func call(arguments: Arguments) async throws -> String {
        // same logic as CopilotSDK version
    }
}
```

## Implementation Plan

### Phase 1: Apple FM Tool Wrappers
- Create `AppleCameraTools.swift` — implements Apple's `Tool` protocol
- Ultra-compact: 5 tools max
- Uses same CameraService/SceneAnalyzer/VoiceService

### Phase 2: Session Runner
- Create `AppleCameraSession.swift` — wraps `LanguageModelSession`
- Provides same `run(prompt:)` interface as CopilotAgent
- Handles context window limits (auto-summarize)

### Phase 3: Unified API
- `CameraAgent` protocol with `run(prompt:)`
- `CopilotCameraAgent` — backed by CopilotSDK
- `LocalCameraAgent` — backed by Foundation Models
- App can switch based on availability/preference

## Constraints
- **iOS 26+ only** for Foundation Models (beta, ships Fall 2025)
- **Apple Intelligence must be enabled** on device
- **On-device model is smaller** — simpler instructions, fewer tools
- **Context window is limited** — can't accumulate many tool results
- **Image input**: Not clear if FM supports base64 images in prompts
  - May need to always use `analyze_frame` instead of `observe_camera`
  - Or use Vision framework as pre-processing before prompting

## Image Handling

The on-device FM is text-only. The camera agent pattern changes:
- CopilotSDK: send base64 image → model "sees" it
- Apple FM: send Vision analysis text → model "understands" it

This means `observe_camera` for Apple FM should return analysis text, not an image.
The compact `analyze_frame` tool becomes the primary "eyes".
