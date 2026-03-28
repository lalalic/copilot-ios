# Camera Animation System

## Overview

CameraKit's animation system enables smooth, keyframe-based camera parameter transitions — like CSS animations but for real camera hardware (zoom, exposure, focus, white balance, ISO, shutter speed).

An AI film director agent can call `animate_camera` to create cinematic camera moves: zoom ramps, focus pulls, exposure shifts, or any combination — all interpolated at 60fps via `CADisplayLink`.

## Architecture

```
AI Agent
  │
  ▼
animate_camera tool (CameraToolProvider)
  │  parses JSON keyframes
  ▼
CameraAnimator (CADisplayLink @ 60Hz)
  │  interpolates with easing curves
  ▼
CameraService.setZoom/setExposure/setFocus/...
  │  applies to hardware
  ▼
AVCaptureDevice (lockForConfiguration)
```

## Components

### AnimationEasing

Easing functions that map normalized time `t ∈ [0,1]` through a curve:

| Easing | Curve | Use Case |
|--------|-------|----------|
| `linear` | Constant speed | Smooth pans |
| `ease_in` | Cubic acceleration | Dramatic zoom starts |
| `ease_out` | Cubic deceleration | Gentle zoom stops |
| `ease_in_out` | Cubic S-curve | Natural camera moves |
| `spring` | Damped oscillation | Energetic, organic feel |

Spring accepts `damping` (0-1, default 0.7) and `stiffness` (default 100).

### CameraKeyframe

A snapshot of camera parameter values at a specific time:

```swift
CameraKeyframe(
    time: 2.0,           // seconds from animation start
    easing: .easeInOut,  // curve to NEXT keyframe
    zoom: 3.0,           // zoom level (1.0 = normal)
    exposure: 0.5,       // EV compensation (-2 to +2)
    focusX: 0.5,         // focus point X (0-1)
    focusY: 0.3,         // focus point Y (0-1)
    whiteBalance: 5500,  // Kelvin (0 = auto)
    iso: 200,            // ISO sensitivity
    shutterSpeed: 0.008  // seconds (1/125s)
)
```

All parameters except `time` are optional — only non-nil values are animated.

### CameraAnimator

The animation engine:
- Uses `CADisplayLink` targeting 60fps (30-120fps adaptive range)
- Interpolates between keyframes using the lower keyframe's easing curve
- Applies interpolated values to `CameraService` each frame
- `async` API that suspends until animation completes
- Can be stopped mid-animation via `stop()`

### animate_camera Tool

AI agent tool format:

```json
{
    "keyframes": [
        {"time": 0, "zoom": 1.0},
        {"time": 2, "zoom": 3.0, "easing": "ease_in_out"},
        {"time": 4, "zoom": 1.5, "easing": "ease_out"}
    ],
    "duration": 4,
    "record": true
}
```

Parameters:
- `keyframes` (required): Array of keyframe objects with `time` + optional parameter values
- `duration` (optional): Total animation seconds (default: last keyframe time)
- `record` (optional): Auto-start/stop recording during animation (default: false)

## Example Scenarios

### Dramatic Zoom Ramp
```json
{
    "keyframes": [
        {"time": 0, "zoom": 1.0},
        {"time": 3, "zoom": 5.0, "easing": "ease_in"}
    ],
    "record": true
}
```

### Focus Pull (Rack Focus)
```json
{
    "keyframes": [
        {"time": 0, "focus_x": 0.3, "focus_y": 0.4},
        {"time": 1.5, "focus_x": 0.7, "focus_y": 0.6, "easing": "ease_in_out"}
    ]
}
```

### Cinematic Reveal (Zoom + Exposure)
```json
{
    "keyframes": [
        {"time": 0, "zoom": 1.0, "exposure": -1.0},
        {"time": 2, "zoom": 2.0, "exposure": 0, "easing": "ease_out"},
        {"time": 5, "zoom": 3.0, "exposure": 0.5, "easing": "ease_in_out"}
    ],
    "record": true
}
```

### Spring Bounce Zoom
```json
{
    "keyframes": [
        {"time": 0, "zoom": 1.0},
        {"time": 2, "zoom": 2.5, "easing": "spring"}
    ]
}
```

## Integration

The animator is accessible via `CameraToolProvider.animator`:

```swift
let provider = CameraToolProvider(camera: cameraService)

// Use via tool system (AI agent)
let tools = provider.allTools  // includes animate_camera

// Or use directly
await provider.animator.animate(keyframes: [...], duration: 5.0)
```

## Skills

`animate_camera` is included in:
- **Film Director** (both regular and compact tool sets)
- **Product Photographer** (regular tool set)

## Technical Notes

- `CADisplayLink` runs on the main run loop for guaranteed frame accuracy
- `nonisolated(unsafe)` used for `displayLink` property to satisfy Swift 6 concurrency (safe because it's only accessed on `@MainActor`)
- The tool handler bridges from the `@Sendable` context to `@MainActor` via `withCheckedContinuation` + `Task { @MainActor }`
- Camera parameter changes use `AVCaptureDevice.lockForConfiguration()` — rapid calls at 60fps work correctly on iOS
- Optional auto-record: starts recording 200ms before animation begins for capture stabilization
