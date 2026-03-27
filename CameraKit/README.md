# CameraKit

A reusable Swift package that turns an iPhone into an AI-directed camera operator.
Provides camera, voice, and scene analysis services with **dual backend** support:
[CopilotSDK](../CopilotSDK/) (cloud) and [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels) (on-device).

## Quick Start

### Cloud Backend (CopilotSDK)

```swift
import CameraKit
import CopilotSDK

let camera = CameraService()
let toolProvider = CameraToolProvider(camera: camera)

let agent = try await client.createAgent(config: AgentConfig(
    instructions: CameraSkill.filmDirector.systemPrompt,
    tools: toolProvider.compactTools(for: .filmDirector),
    onResponse: { print("Director: \($0)") },
    onAskUser: { _ in readLine()! }
))
try await agent.start(prompt: "Film a cooking tutorial")
```

### On-Device Backend (Apple Foundation Models, iOS 26+)

```swift
import CameraKit

let camera = CameraService()
let agent = AppleCameraAgent(camera: camera)
let response = try await agent.run(prompt: "Direct me through filming a product review")
```

### Hybrid (Best of Both)

```swift
func runAgent(prompt: String) async throws -> String {
    if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
        return try await AppleCameraAgent(camera: camera).run(prompt: prompt)
    } else {
        let agent = try await client.createAgent(config: agentConfig)
        return try await agent.start(prompt: prompt)
    }
}
```

## Architecture

```
+-------------------------------------------+
|            CameraKit Services             |
|   CameraService . SceneAnalyzer . Voice   |
|          (Backend-agnostic)               |
+------------------+------------------------+
                   |
           +-------+-------+
           v               v
+--------------+  +------------------+
| CopilotSDK   |  | Apple Foundation |
| ToolProvider  |  | Models Tools     |
| 32 tools     |  | 6 ultra-compact  |
| ToolDefinition|  | Tool protocol    |
+---------+----+  +--------+---------+
          |                |
          v                v
     CopilotClient   LanguageModelSession
     (Cloud GPT-4o)  (On-device, private)
```

## Tools (32 total)

### Observation
| Tool | Description |
|------|-------------|
| `observe_camera` | Capture current camera frame as base64 JPEG |
| `get_scene_analysis` | On-device Vision AI: scene labels, text, lighting, saliency |

### Voice
| Tool | Description |
|------|-------------|
| `speak` | Text-to-speech output |
| `listen` | Speech recognition input (configurable duration) |

### Recording
| Tool | Description |
|------|-------------|
| `start_recording` | Start video recording with optional shot name |
| `stop_recording` | Stop recording, returns duration and file path |
| `pause_recording` | Pause current recording without stopping |
| `resume_recording` | Resume paused recording |
| `capture_photo` | Capture a still photo |

### Camera Controls
| Tool | Description |
|------|-------------|
| `set_camera` | Set position (front/back) and lens (wide/ultraWide/telephoto) |
| `set_zoom` | Zoom level (1.0 = normal) |
| `switch_camera` | Toggle front/back camera |
| `set_exposure` | Exposure compensation (-2.0 to +2.0 EV) |
| `set_manual_exposure` | Manual ISO and shutter speed |
| `set_focus` | Focus point (normalized 0-1 coordinates) |
| `set_flash` | Flash mode: off, on, auto, torch |
| `set_white_balance` | Color temperature in Kelvin (2700-7500K) or auto |
| `set_slow_motion` | Framerate: normal (30fps), slo120 (120fps), slo240 (240fps) |
| `get_device_info` | Query device capabilities (lenses, zoom range, ISO, FPS) |

### Vision Analysis
| Tool | Description |
|------|-------------|
| `detect_objects` | Detect objects/animals with positions and confidence |
| `detect_faces` | Find faces with position, size, and head orientation |
| `detect_pose` | Detect human body poses with joint positions |
| `detect_horizon` | Check if camera is level (tilt angle, +/-2 deg tolerance) |
| `detect_blur` | Sharpness score (0-1) and feedback |
| `classify_shot` | Shot type: extreme close-up, close-up, medium, wide, establishing |
| `classify_scene` | Scene type: talking head, interview, vlog, product demo, landscape |
| `detect_rectangles` | Find rectangular shapes (screens, documents, whiteboards) |
| `track_subject` | Track an object across frames using bounding box |

### Director
| Tool | Description |
|------|-------------|
| `analyze_shot` | Comprehensive: scene + faces + poses + composition quality |

### Audio
| Tool | Description |
|------|-------------|
| `get_audio_levels` | Real-time audio metering (0-1 level + description) |

### Image Generation
| Tool | Description |
|------|-------------|
| `generate_image` | Create stylized images via Apple Image Playground |

### Timing
| Tool | Description |
|------|-------------|
| `wait` | Pause agent execution (1-30 seconds) |

## Tool Modes

| Mode | Tools | Best For |
|------|-------|----------|
| **Granular** (`allTools`) | 32 | Cloud models (GPT-4o), fine-grained control |
| **Compact** (`compactTools`) | 14 | Fewer round-trips, still cloud |
| **Apple FM** (`AppleCameraAgent`) | 6 | On-device, offline, privacy-first |

### Compact Mode

Two unified tools replace many granular ones:

- **`configure_camera`** replaces 10 tools (set_camera, zoom, exposure, focus, flash, WB, slow-mo, device info)
- **`analyze_vision`** replaces 10 tools (scene, objects, faces, pose, shot, horizon, blur, scene type, rectangles)

```swift
let tools = toolProvider.compactTools
let tools = toolProvider.compactTools(for: .filmDirector)
```

### Apple FM Mode (On-Device)

Ultra-compact 6 tools (Apple recommends 3-5):

| Apple FM Tool | Replaces |
|---------------|----------|
| `camera_action` | All camera controls + recording |
| `analyze_frame` | All vision + scene analysis |
| `speak` | TTS |
| `listen` | Speech recognition |
| `generate_image` | Image Playground |
| `wait` | Timing |

On-device model is text-only. `analyze_frame` converts camera frames to text via Vision framework.

## Skills

| Skill | Key Tools | Use Case |
|-------|-----------|----------|
| **Film Director** | recording, voice, faces, tracking, slow-mo, audio, image gen | Direct short films |
| **Portrait Photographer** | photo, exposure, focus, face/pose, blur | Portrait sessions |
| **Scene Scout** | analysis, objects, horizon, scene type, rectangles | Location scouting |
| **Timelapse Operator** | scene, exposure, white balance, horizon, blur | Adaptive timelapse |
| **Product Photographer** | photo, exposure, flash, objects, blur, rectangles, image gen | Product photos |

```swift
let tools = toolProvider.tools(for: .portraitPhotographer)
let tools = toolProvider.compactTools(for: .filmDirector)
```

## Services API

### CameraService

```swift
let camera = CameraService()
camera.requestAccess()
camera.startSession()

camera.setCamera(position: .back, lens: .telephoto)
camera.setExposure(0.5)
camera.setManualExposure(iso: 400, shutterSpeed: 0.01)
camera.setWhiteBalance(temperature: 5500)
camera.setFocus(x: 0.5, y: 0.3)
camera.setSlowMotion(.slo120)

camera.startRecording()
camera.pauseRecording()
camera.resumeRecording()
let url = await camera.stopRecording()

camera.startAudioMonitoring()
camera.audioLevel  // 0-1 Float
camera.stopAudioMonitoring()

let photo = await camera.capturePhoto()
let frame = camera.getLatestFrameBase64(quality: 0.1)
```

### SceneAnalyzer

```swift
let analyzer = SceneAnalyzer()

let scene = await analyzer.analyze(pixelBuffer: frame)
let faces = await analyzer.detectFaces(pixelBuffer: frame)
let poses = await analyzer.detectPoses(pixelBuffer: frame)
let horizon = await analyzer.detectHorizon(pixelBuffer: frame)
let blur = await analyzer.detectBlur(pixelBuffer: frame)
let shotType = analyzer.classifyShotType(faces: faces)
let tracked = await analyzer.trackSubject(initialBBox: bbox, in: frame)
let analysis = await analyzer.analyzeShot(pixelBuffer: frame)
```

### VoiceOutput / VoiceInput

```swift
let voice = VoiceOutput()
voice.speak("Look left!")

let input = VoiceInput()
let text = await input.listen(duration: 5)
```

## Callbacks

```swift
toolProvider.onRecordStart = { showIndicator = true }
toolProvider.onRecordStop = { url, duration in clips.append(url!) }
toolProvider.onFinish = { navigateToReview = true }
```

## Requirements

| Backend | Min OS | Dependencies |
|---------|--------|-------------|
| CopilotSDK (cloud) | iOS 18+ | [CopilotSDK](../CopilotSDK/) |
| Apple FM (on-device) | iOS 26+ | None (system) |
| Image Playground | iOS 18.4+ | None (system) |

Swift 6.0, Xcode 16+

## Package Structure

```
CameraKit/
  Sources/
    CameraService.swift       # AVFoundation + slow-mo + audio monitoring
    VoiceService.swift        # TTS + speech recognition
    SceneAnalyzer.swift       # Vision: scene, face, pose, horizon, blur, tracking
    CameraToolProvider.swift  # 32 ToolDefinitions (CopilotSDK)
    CameraSkill.swift         # 5 skill presets
    AppleCameraTools.swift    # 6 FM tools + AppleCameraAgent
  Tests/
    CameraKitTests.swift
  docs/
    apple-fm-design.md
    apple-intelligence-apis.md
```
