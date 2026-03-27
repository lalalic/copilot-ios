# Apple Intelligence APIs: Image Generation, Visual Intelligence & Offline

## 1. Image/Emoji Generation — Can Tools Create Images?

### Image Playground (`ImagePlayground` framework)
- **Available**: iOS 18.1+ (already shipping!)
- **Two modes**:
  - **UI-based**: `ImagePlaygroundViewController` / `.imagePlaygroundSheet()` — presents system UI, user picks style and approves
  - **Programmatic**: `ImageCreator` (iOS 18.4+) — **generates images without UI**!

```swift
// Programmatic image generation — no user interaction needed
let creator = try await ImageCreator()
let concepts: [ImagePlaygroundConcept] = [
    .text("a sunset over mountains"),
    // .image(sourceImage)  // optional source image for style transfer
]
for try await result in creator.images(for: concepts, style: .animation, limit: 1) {
    let cgImage = result.image  // Generated CGImage
}
```

- **Styles**: `.animation`, `.illustration`, `.sketch` (cartoon-ish, not photorealistic)
- **Limitations**: 
  - Apple controls quality/style — can't generate photorealistic images
  - Subject to content moderation (no inappropriate content)
  - Styles are limited to Apple's predefined set
  - **Not** a Stable Diffusion replacement — stylized illustrations only

### Genmoji
- **No public API** — Genmoji is system-keyboard-only
- Users create custom emoji in the system keyboard
- Apps can _display_ Genmoji but can't _generate_ them programmatically
- **Not usable for camera agent tools**

### Camera Agent Integration
A tool like `generate_thumbnail` could use `ImageCreator`:
```swift
struct GenerateImageTool: Tool {
    // Agent analyzes scene → describes it → generates stylized thumbnail
    func call(arguments: Arguments) async throws -> String {
        let creator = try await ImageCreator()
        let concepts: [ImagePlaygroundConcept] = [.text(arguments.description)]
        for try await result in creator.images(for: concepts, style: .animation, limit: 1) {
            // Save or display the generated image
            return "Generated image saved"
        }
    }
}
```
**Use case**: Agent shoots a video → analyzes best frame → generates a stylized thumbnail/poster for the video.

---

## 2. Visual Intelligence API — What Is It?

### What it IS
- **Search integration API** (iOS 26+)
- Lets your app **appear in Visual Intelligence search results**
- When user points camera at something (via system Visual Intelligence feature), your app can return matching content
- Uses `SemanticContentDescriptor` + `App Intents` framework

### What it is NOT
- **Not** a programmatic vision/image understanding API
- **Not** something your app calls to analyze images
- **Not** a replacement for Vision framework
- The system calls YOUR app, not the other way around

### How it works:
1. User opens Visual Intelligence (system camera feature)
2. Points at an object (e.g., a restaurant, a product)
3. System identifies objects and searches registered apps
4. Your app can register via App Intents to be a search result
5. User sees your app's results alongside others

### For CameraKit: NOT directly useful
Visual Intelligence is for "be discoverable when users scan things" — not for "analyze images programmatically." We already have better coverage via:
- **Vision framework** (what SceneAnalyzer uses) — face, object, scene, text, horizon, pose detection
- **Foundation Models** — text understanding and tool calling

### BUT — App Intents integration IS useful
We could expose CameraKit skills as **App Intents** → Siri shortcuts → Apple Intelligence automation:
```swift
// "Hey Siri, direct a video" → launches camera agent
struct DirectVideoIntent: AppIntent {
    static var title: LocalizedStringResource = "Direct a Video"
    func perform() async throws -> some IntentResult {
        // Launch camera agent with film director skill
    }
}
```

---

## 3. Offline Viability — Is Foundation Models a Full Offline Solution?

### YES, with caveats

**What works offline (Foundation Models):**
- ✅ Text generation (respond to prompts)
- ✅ Tool calling (model calls your Swift tools)
- ✅ Structured output (`@Generable` types)
- ✅ Multi-turn conversation (transcript)
- ✅ Streaming responses
- ✅ All on-device, no network required

**What works offline (existing CameraKit):**
- ✅ Camera controls (AVFoundation)
- ✅ Vision analysis (Vision framework — all on-device)
- ✅ Face/pose/object detection
- ✅ Scene classification
- ✅ TTS (AVSpeechSynthesizer — on-device)
- ✅ Speech recognition (SFSpeechRecognizer — has on-device mode)
- ✅ Image generation (ImageCreator — on-device)

### The camera agent CAN run 100% offline with Apple FM

The entire pipeline is on-device:
```
User speaks → SFSpeechRecognizer (on-device)
  → Foundation Models LLM (on-device tool calling)
    → Vision framework analysis (on-device)
    → Camera controls (AVFoundation)
  → AVSpeechSynthesizer response (on-device)
```

### Limitations vs Cloud (CopilotSDK)

| Feature | Apple FM (offline) | CopilotSDK (cloud) |
|---------|-------------------|-------------------|
| **Model size** | ~3B params (on-device) | GPT-4o / Claude (huge) |
| **Reasoning** | Simple tasks, short chains | Complex multi-step reasoning |
| **Context window** | Small (~4K tokens?) | 128K+ tokens |
| **Tool count** | 3-5 recommended | 30+ supported |
| **Image understanding** | NO (text-only LLM) | YES (multimodal) |
| **Latency** | ~instant | Network dependent |
| **Privacy** | 100% on-device | Data leaves device |
| **Cost** | Free | API credits |
| **Availability** | iOS 26+, AI-capable devices | iOS 16+ |

### Hybrid Strategy (Best of Both)

```swift
// Try on-device first, fall back to cloud
func runCameraAgent(prompt: String) async throws -> String {
    if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
        // Fast, private, offline
        let agent = AppleCameraAgent(camera: camera)
        return try await agent.run(prompt: prompt)
    } else {
        // More capable, needs network
        let agent = try await CopilotClient.createAgent(config: AgentConfig(...))
        return try await agent.run(prompt: prompt)  
    }
}
```

### Key Takeaway
Apple Foundation Models **is a legitimate offline solution** for the camera agent use case because:
1. Camera direction is a relatively simple task (analyze scene → give instructions → adjust camera)
2. Only needs 5 tools (our ultra-compact set fits Apple's 3-5 recommendation)
3. The heavy lifting (vision analysis, camera control) is already on-device via Vision/AVFoundation
4. The LLM just needs to orchestrate — connect scene understanding to camera actions
5. Short spoken responses fit the small context window

The main gap is **no image understanding** — the on-device LLM can't "see" photos. But our `analyze_frame` tool bridges this by converting camera frames to text descriptions via Vision framework. The model never needs to see the image directly.

---

## Summary

| API | Camera Agent Use | Priority |
|-----|-----------------|----------|
| **Foundation Models** | ✅ On-device LLM backbone (offline!) | **Implemented** |
| **Image Playground / ImageCreator** | ✅ Generate stylized thumbnails/posters | **Could add as tool** |
| **Visual Intelligence** | ❌ Not for programmatic vision (it's for app discovery) | Skip |
| **App Intents / Siri** | ✅ "Hey Siri, direct a video" | Future |
| **Genmoji** | ❌ No public API | Skip |
| **Writing Tools** | ❌ Not relevant for camera | Skip |
