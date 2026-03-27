# iOS Dual-Camera & Fancy Camera Effects Research

> Research date: 2026-03-26

## Table of Contents
1. [Simultaneous Front + Back Recording](#1-simultaneous-front--back-recording)
2. [AVCaptureMultiCamSession Deep Dive](#2-avcapturemulticamsession-deep-dive)
3. [Setting Up Multi-Cam Recording](#3-setting-up-multi-cam-recording)
4. [Picture-in-Picture Recording](#4-picture-in-picture-recording)
5. [Multi-Cam Limitations](#5-multi-cam-limitations)
6. [Simpler Alternatives](#6-simpler-alternatives)
7. [Smooth Zoom Animations](#7-smooth-zoom-animations)
8. [Animated Exposure & Focus](#8-animated-exposure--focus)
9. [Depth-of-Field / Bokeh Control](#9-depth-of-field--bokeh-control)
10. [Cinematic Mode & iOS 17/18/26 APIs](#10-cinematic-mode--ios-171826-apis)

---

## 1. Simultaneous Front + Back Recording

**Yes, iOS supports recording from front and back cameras simultaneously** using `AVCaptureMultiCamSession`.

Before iOS 13, `AVCaptureSession` only allowed one camera input at a time. If you added a front camera input, you had to remove the back camera input first (exactly what our current `CameraService.switchCamera()` does).

Starting with **iOS 13**, Apple introduced `AVCaptureMultiCamSession` which allows:
- Multiple camera inputs simultaneously
- Multiple video outputs (one per camera)
- Multiple preview layers (one per camera)
- Independent configuration per camera connection

**Key API:**
```swift
import AVFoundation

// Instead of AVCaptureSession, use:
let multiCamSession = AVCaptureMultiCamSession()

// Check device support first:
guard AVCaptureMultiCamSession.isMultiCamSupported else {
    print("Multi-cam not supported on this device")
    return
}
```

---

## 2. AVCaptureMultiCamSession Deep Dive

### What Is It?
`AVCaptureMultiCamSession` is a subclass of `AVCaptureSession` that lifts the single-camera restriction. It manages multiple hardware cameras concurrently, handling resource contention (power, thermal, memory bandwidth) automatically.

### iOS Version
- **Introduced: iOS 13.0** (WWDC 2019, session "What's New in Camera Capture")
- Available on iPadOS 13.0 as well
- **Not available on macOS** (macOS uses different multi-camera approaches)

### Device Support
Multi-cam requires **specific hardware**. The `isMultiCamSupported` class property checks this at runtime.

**Supported devices (minimum):**
- iPhone XS / XS Max / XR and later (A12 Bionic+)
- iPad Pro (3rd generation, 2018) and later
- **NOT supported:** iPhone X, iPhone 8/8 Plus, or earlier

The hardware requirement is the ISP (Image Signal Processor) in A12+ chips that can handle multiple camera pipelines simultaneously.

### Supported Camera Combinations
Not every combination works. Apple documents these via `AVCaptureDevice.DiscoverySession`:

```swift
// Query supported multi-cam device sets
let discoverySession = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
    mediaType: .video,
    position: .unspecified
)

// supportedMultiCamDeviceSets tells you which combos work together
for deviceSet in discoverySession.supportedMultiCamDeviceSets {
    let names = deviceSet.map { "\($0.localizedName) (\($0.position == .front ? "front" : "back"))" }
    print("Supported combo: \(names.joined(separator: " + "))")
}
```

**Typical supported combinations on iPhone 15 Pro:**
- Back Wide + Front Wide ✅
- Back Ultra-Wide + Front Wide ✅  
- Back Telephoto + Front Wide ✅
- Back Wide + Back Ultra-Wide ✅ (dual back cameras)
- Back Wide + Back Ultra-Wide + Front Wide ✅ (triple!)
- Back Wide + Back Telephoto ✅

**Not supported:**
- Back Ultra-Wide + Back Telephoto (typically)
- Three back cameras simultaneously

---

## 3. Setting Up Multi-Cam Recording

### Complete Setup Code

```swift
import AVFoundation
import UIKit

class MultiCamRecorder: NSObject {
    let multiCamSession = AVCaptureMultiCamSession()
    
    // Back camera
    private var backDeviceInput: AVCaptureDeviceInput?
    private var backVideoOutput = AVCaptureVideoDataOutput()
    private var backPreviewLayer: AVCaptureVideoPreviewLayer?
    
    // Front camera  
    private var frontDeviceInput: AVCaptureDeviceInput?
    private var frontVideoOutput = AVCaptureVideoDataOutput()
    private var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    
    // Audio
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var backAudioOutput = AVCaptureAudioDataOutput()
    
    // Asset writers for recording
    private var assetWriter: AVAssetWriter?
    private var backVideoWriterInput: AVAssetWriterInput?
    private var frontVideoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    
    private let dataOutputQueue = DispatchQueue(label: "multicam.dataOutput")
    
    func setupSession() throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw NSError(domain: "MultiCam", code: -1, 
                         userInfo: [NSLocalizedDescriptionKey: "Multi-cam not supported"])
        }
        
        multiCamSession.beginConfiguration()
        
        // --- Back Camera ---
        guard let backCamera = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else { throw NSError(domain: "MultiCam", code: -2) }
        
        let backInput = try AVCaptureDeviceInput(device: backCamera)
        guard multiCamSession.canAddInput(backInput) else { throw NSError(domain: "MultiCam", code: -3) }
        multiCamSession.addInputWithNoConnections(backInput)
        self.backDeviceInput = backInput
        
        // Find the video port for back camera
        guard let backVideoPort = backInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first else {
            throw NSError(domain: "MultiCam", code: -4)
        }
        
        // Back video data output
        backVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard multiCamSession.canAddOutput(backVideoOutput) else { throw NSError(domain: "MultiCam", code: -5) }
        multiCamSession.addOutputWithNoConnections(backVideoOutput)
        
        // Connect back camera port → back video output
        let backConnection = AVCaptureConnection(inputPorts: [backVideoPort], output: backVideoOutput)
        guard multiCamSession.canAddConnection(backConnection) else { throw NSError(domain: "MultiCam", code: -6) }
        multiCamSession.addConnection(backConnection)
        backConnection.videoOrientation = .portrait
        
        // --- Front Camera ---
        guard let frontCamera = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ) else { throw NSError(domain: "MultiCam", code: -7) }
        
        let frontInput = try AVCaptureDeviceInput(device: frontCamera)
        guard multiCamSession.canAddInput(frontInput) else { throw NSError(domain: "MultiCam", code: -8) }
        multiCamSession.addInputWithNoConnections(frontInput)
        self.frontDeviceInput = frontInput
        
        guard let frontVideoPort = frontInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .front).first else {
            throw NSError(domain: "MultiCam", code: -9)
        }
        
        // Front video data output
        frontVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard multiCamSession.canAddOutput(frontVideoOutput) else { throw NSError(domain: "MultiCam", code: -10) }
        multiCamSession.addOutputWithNoConnections(frontVideoOutput)
        
        let frontConnection = AVCaptureConnection(inputPorts: [frontVideoPort], output: frontVideoOutput)
        guard multiCamSession.canAddConnection(frontConnection) else { throw NSError(domain: "MultiCam", code: -11) }
        multiCamSession.addConnection(frontConnection)
        frontConnection.videoOrientation = .portrait
        frontConnection.isVideoMirrored = true  // Mirror front camera
        
        // --- Audio (shared, typically from back mic) ---
        if let mic = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: mic)
            if multiCamSession.canAddInput(audioInput) {
                multiCamSession.addInputWithNoConnections(audioInput)
                self.audioDeviceInput = audioInput
                
                if let audioPort = audioInput.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: .unspecified).first {
                    if multiCamSession.canAddOutput(backAudioOutput) {
                        multiCamSession.addOutputWithNoConnections(backAudioOutput)
                        let audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: backAudioOutput)
                        if multiCamSession.canAddConnection(audioConnection) {
                            multiCamSession.addConnection(audioConnection)
                        }
                    }
                }
            }
        }
        
        multiCamSession.commitConfiguration()
        
        // Set delegates
        backVideoOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
        frontVideoOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
        backAudioOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
    }
    
    // --- Preview Layers ---
    func createBackPreviewLayer(for view: UIView) -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer()
        layer.setSessionWithNoConnection(multiCamSession)
        layer.videoGravity = .resizeAspectFill
        
        // Connect to back camera port
        if let backPort = backDeviceInput?.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first {
            let connection = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: layer)
            if multiCamSession.canAddConnection(connection) {
                multiCamSession.addConnection(connection)
            }
        }
        
        view.layer.addSublayer(layer)
        layer.frame = view.bounds
        self.backPreviewLayer = layer
        return layer
    }
    
    func createFrontPreviewLayer(for view: UIView) -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer()
        layer.setSessionWithNoConnection(multiCamSession)
        layer.videoGravity = .resizeAspectFill
        
        if let frontPort = frontDeviceInput?.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .front).first {
            let connection = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: layer)
            connection.isVideoMirrored = true
            if multiCamSession.canAddConnection(connection) {
                multiCamSession.addConnection(connection)
            }
        }
        
        view.layer.addSublayer(layer)
        layer.frame = view.bounds
        self.frontPreviewLayer = layer
        return layer
    }
    
    func startRunning() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.multiCamSession.startRunning()
        }
    }
}
```

### Key Differences from Regular AVCaptureSession

| Feature | AVCaptureSession | AVCaptureMultiCamSession |
|---------|-----------------|-------------------------|
| Camera inputs | 1 at a time | Multiple simultaneously |
| Add inputs | `addInput()` | `addInputWithNoConnections()` |
| Add outputs | `addOutput()` | `addOutputWithNoConnections()` |
| Connections | Automatic | Manual via `AVCaptureConnection` |
| Preview layers | `init(session:)` | `setSessionWithNoConnection()` + manual connection |
| Session preset | `.high`, `.photo`, etc. | **Not supported** — must configure formats per-device |
| `MovieFileOutput` | ✅ | ❌ Not supported — use `AVAssetWriter` |

**Critical:** `AVCaptureMovieFileOutput` does NOT work with `AVCaptureMultiCamSession`. You must use `AVAssetWriter` to compose the final video from multiple camera streams.

---

## 4. Picture-in-Picture (PiP) Recording

Yes! This is the most common multi-cam use case. You composite the two camera feeds into a single video frame.

### Approach: AVAssetWriter + Core Image Compositing

```swift
extension MultiCamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    // Store latest frames from each camera
    private static var latestBackBuffer: CVPixelBuffer?
    private static var latestFrontBuffer: CVPixelBuffer?
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        if output == backVideoOutput {
            // Back camera frame
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                Self.latestBackBuffer = pixelBuffer
                compositeAndWrite(timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
        } else if output == frontVideoOutput {
            // Front camera frame  
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                Self.latestFrontBuffer = pixelBuffer
            }
        } else if output == backAudioOutput {
            // Audio frame — write directly
            writeAudioSample(sampleBuffer)
        }
    }
    
    /// Composite back (full screen) + front (PiP overlay) into single frame
    func compositeAndWrite(timestamp: CMTime) {
        guard let backBuffer = Self.latestBackBuffer,
              let frontBuffer = Self.latestFrontBuffer else { return }
        
        let ciContext = CIContext()
        
        // Main view: back camera (full frame)
        let backImage = CIImage(cvPixelBuffer: backBuffer)
        
        // PiP: front camera (small overlay)
        var frontImage = CIImage(cvPixelBuffer: frontBuffer)
        
        // Scale front camera to PiP size (e.g., 1/4 of frame)
        let mainWidth = backImage.extent.width
        let mainHeight = backImage.extent.height
        let pipWidth = mainWidth * 0.28
        let pipHeight = mainHeight * 0.28
        
        let scaleX = pipWidth / frontImage.extent.width
        let scaleY = pipHeight / frontImage.extent.height
        let scale = min(scaleX, scaleY)
        
        frontImage = frontImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        // Position: top-right corner with padding
        let padding: CGFloat = 20
        let pipX = mainWidth - (frontImage.extent.width) - padding
        let pipY = mainHeight - (frontImage.extent.height) - padding
        frontImage = frontImage
            .transformed(by: CGAffineTransform(translationX: pipX, y: pipY))
        
        // Optional: Add rounded corners to PiP
        let roundedPiP = frontImage.applyingFilter("CIRoundedRectangleGenerator", parameters: [
            // For actual rounded corners, use a mask approach:
        ])
        
        // Composite: front over back
        let composited = frontImage.composited(over: backImage)
        
        // Render to pixel buffer and write via AVAssetWriter
        if let outputBuffer = createPixelBuffer(width: Int(mainWidth), height: Int(mainHeight)) {
            ciContext.render(composited, to: outputBuffer)
            writeVideoFrame(outputBuffer, timestamp: timestamp)
        }
    }
    
    func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        return buffer
    }
}
```

### SwiftUI Preview Layout

```swift
struct MultiCamPreviewView: View {
    let session: AVCaptureMultiCamSession
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Main camera (back) — full screen
            MultiCamLayerView(session: session, position: .back)
                .ignoresSafeArea()
            
            // PiP camera (front) — small overlay
            MultiCamLayerView(session: session, position: .front)
                .frame(width: 120, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white, lineWidth: 2))
                .shadow(radius: 5)
                .padding(16)
                .draggable() // Make it draggable if desired
        }
    }
}
```

### Alternative: Metal Compositor (Higher Performance)

For real-time compositing at 30/60fps, Core Image may be too slow. A Metal-based approach is better:

```swift
import Metal
import MetalKit

class MetalPiPCompositor {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    
    // Use two texture inputs, render PiP layout in a fragment shader
    // This is significantly more performant than CIContext.render()
    
    func composite(backTexture: MTLTexture, frontTexture: MTLTexture, 
                   pipRect: CGRect) -> MTLTexture {
        // Metal fragment shader handles the compositing in GPU
        // Can also add rounded corners, shadows, borders in the shader
        // ...
    }
}
```

Apple's own sample project **"AVMultiCamPiP"** demonstrates this exact pattern using Metal.

---

## 5. Multi-Cam Limitations

### Resolution Limits
When running multi-cam, the system throttles each camera independently:

| Combination | Back Camera Max | Front Camera Max |
|-------------|----------------|-----------------|
| Back Wide + Front | 1920×1080 (1080p) | 1920×1080 (1080p) |
| Back Wide + Back Ultra-Wide | 1920×1080 each | N/A |
| Triple (2 back + front) | 1280×720 each | 1280×720 |

- **No 4K in multi-cam mode** — the ISP bandwidth is shared
- The system may further reduce resolution under thermal pressure

### Frame Rate
- Typically limited to **30 fps** per camera
- 60 fps may work for some dual combinations on newer devices (A15+)
- **No slow-motion (120/240fps)** in multi-cam mode

### Other Limitations
- **No `AVCaptureMovieFileOutput`** — you must use `AVAssetWriter`
- **No session presets** — configure each device format individually
- **No photo capture from multiple cameras simultaneously** — video only
- **Increased power consumption** — battery drain is ~2x a single camera
- **Thermal throttling** — `AVCaptureDevice.SystemPressureState` will report elevated levels; the system may shut down cameras
- **No LiDAR + multi-cam** — depth data availability varies
- **Audio** — only one audio input, but you can choose which device's mic

### System Pressure Handling
```swift
// Monitor for thermal/resource pressure
NotificationCenter.default.addObserver(
    forName: .AVCaptureSessionRuntimeError, 
    object: multiCamSession, queue: .main
) { notification in
    if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError {
        // May need to fall back to single camera
        print("Multi-cam error: \(error)")
    }
}

// Also observe system pressure on each device
device.addObserver(self, forKeyPath: "systemPressureState", options: .new, context: nil)
```

---

## 6. Simpler Alternatives

### Option A: Rapid Camera Switching (No Multi-Cam)
If you just need both perspectives but not simultaneously:
```swift
// Record from back camera → stop → switch → record from front → combine in post
// Works on ALL devices, no multi-cam needed
```

### Option B: ReplayKit with Camera Overlay
```swift
import ReplayKit

// ReplayKit can record the screen with a camera overlay
let recorder = RPScreenRecorder.shared()
recorder.isCameraEnabled = true
recorder.cameraPosition = .front
// The front camera appears as a movable overlay in the recording
// But this records the SCREEN, not just the camera
```

### Option C: Two Separate AVCaptureSession Instances (iOS 16+)
Starting iOS 16, you can use two separate `AVCaptureSession` instances on supported hardware, but this is essentially what `AVCaptureMultiCamSession` does under the hood with less control.

### Option D: Sequential Recording + Composition
Record back camera → switch → record front camera → use `AVMutableComposition` to create PiP in post-processing. Most compatible approach.

---

## 7. Smooth Zoom Animations

### `rampToVideoZoomFactor(withRate:)`

This is the **primary API** for smooth zoom animations on iOS:

```swift
func animateZoom(to factor: CGFloat, rate: Float = 2.0) {
    guard let device = currentVideoDevice else { return }
    let clamped = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
    
    do {
        try device.lockForConfiguration()
        
        // Smooth animated zoom — the hardware interpolates frames
        // rate = zoom factors per second (e.g., 2.0 means 2x per second)
        device.ramp(toVideoZoomFactor: clamped, withRate: rate)
        
        device.unlockForConfiguration()
    } catch {
        print("Zoom animation error: \(error)")
    }
}

// To cancel an in-progress ramp:
func cancelZoomRamp() {
    guard let device = currentVideoDevice else { return }
    do {
        try device.lockForConfiguration()
        device.cancelVideoZoomRamp()
        device.unlockForConfiguration()
    } catch {}
}
```

**KVO Observation** to track animated zoom progress:
```swift
// Observe videoZoomFactor changes during ramp
device.addObserver(self, forKeyPath: "videoZoomFactor", options: [.new], context: nil)

override func observeValue(forKeyPath keyPath: String?, of object: Any?, 
                          change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    if keyPath == "videoZoomFactor", let newZoom = change?[.newKey] as? CGFloat {
        DispatchQueue.main.async {
            self.currentZoom = newZoom
        }
    }
}
```

### Spring-Like Zoom with Combine/Timer

`rampToVideoZoomFactor` uses linear interpolation. For spring physics:

```swift
import Combine

func springZoom(to target: CGFloat, damping: CGFloat = 0.7, stiffness: CGFloat = 100) {
    guard let device = currentVideoDevice else { return }
    
    var velocity: CGFloat = 0
    var current = device.videoZoomFactor
    let maxZoom = device.activeFormat.videoMaxZoomFactor
    
    // 60Hz update loop simulating spring physics
    Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { timer in
        let displacement = current - target
        let springForce = -stiffness * displacement
        let dampingForce = -damping * velocity * 2 * sqrt(stiffness)
        let acceleration = springForce + dampingForce
        
        velocity += acceleration * (1.0/60.0)
        current += velocity * (1.0/60.0)
        current = max(1.0, min(current, maxZoom))
        
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = current
            device.unlockForConfiguration()
        } catch {}
        
        // Stop when settled
        if abs(velocity) < 0.01 && abs(current - target) < 0.01 {
            timer.invalidate()
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = max(1.0, min(target, maxZoom))
                device.unlockForConfiguration()
            } catch {}
        }
    }
}
```

### displayVideoZoomFactorMultiplier (iOS 17+)

iOS 17 added virtual zoom factor ranges that account for lens switching:
```swift
// On iPhone 15 Pro: 
// - Ultra-wide: 0.5x
// - Wide: 1x  
// - Telephoto: 5x
// The system handles smooth transitions across lens boundaries
if let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
    // The triple camera handles zoom across all 3 lenses seamlessly
    // virtualDeviceSwitchOverVideoZoomFactors indicates transition points
    let switchPoints = device.virtualDeviceSwitchOverVideoZoomFactors
    print("Lens switch points: \(switchPoints)") // e.g., [2.0, 5.0]
}
```

---

## 8. Animated Exposure & Focus

### Exposure Animation
`AVCaptureDevice` does **not** provide a built-in `ramp` function for exposure like it does for zoom. However:

```swift
// Method 1: Smooth exposure bias change (system handles transition)
func setExposureBiasAnimated(_ bias: Float) {
    guard let device = currentVideoDevice else { return }
    do {
        try device.lockForConfiguration()
        // This already transitions smoothly — the hardware interpolates
        device.setExposureTargetBias(bias) { _ in
            // Completion handler called when bias reached
        }
        device.unlockForConfiguration()
    } catch {}
}

// Method 2: Animated custom exposure (ISO + duration)
// setExposureModeCustom also transitions smoothly:
func animateExposure(iso: Float, duration: CMTime) {
    guard let device = currentVideoDevice else { return }
    do {
        try device.lockForConfiguration()
        device.setExposureModeCustom(duration: duration, iso: iso) { _ in
            // Called when the new exposure is reached
        }
        device.unlockForConfiguration()
    } catch {}
}
```

**Note:** The hardware naturally smooths exposure transitions to avoid jarring brightness changes. The completion handler tells you when the target is reached.

### Focus Animation
Focus changes are **inherently animated** by the lens motor:

```swift
// Autofocus with point of interest — the lens physically moves
func animateFocus(to point: CGPoint) {
    guard let device = currentVideoDevice else { return }
    do {
        try device.lockForConfiguration()
        device.focusPointOfInterest = point
        device.focusMode = .autoFocus  // Triggers lens movement
        // .autoFocus does a one-shot focus then locks
        // .continuousAutoFocus keeps adjusting
        device.unlockForConfiguration()
    } catch {}
}

// Locked focus at specific lens position (0.0 = near, 1.0 = far)
func setFocusPosition(_ position: Float) {
    guard let device = currentVideoDevice, device.isLockingFocusWithCustomLensPositionSupported else { return }
    do {
        try device.lockForConfiguration()
        device.setFocusModeLocked(lensPosition: position) { _ in
            // Called when lens reaches position
        }
        device.unlockForConfiguration()
    } catch {}
}
```

### Spring-Like Focus Pull (Custom)
For a "rack focus" cinematic effect with spring physics:

```swift
func springFocusPull(to targetPosition: Float, duration: TimeInterval = 0.8) {
    guard let device = currentVideoDevice else { return }
    
    let startPosition = device.lensPosition
    let startTime = CACurrentMediaTime()
    
    Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { timer in
        let elapsed = CACurrentMediaTime() - startTime
        let t = min(Float(elapsed / duration), 1.0)
        
        // Ease-in-out cubic for smooth rack focus feel
        let eased: Float
        if t < 0.5 {
            eased = 4 * t * t * t
        } else {
            let f = (2 * t) - 2
            eased = 0.5 * f * f * f + 1
        }
        
        let current = startPosition + (targetPosition - startPosition) * eased
        
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: current)
            device.unlockForConfiguration()
        } catch {}
        
        if t >= 1.0 { timer.invalidate() }
    }
}
```

---

## 9. Depth-of-Field / Bokeh Control

### Portrait Mode Depth/Bokeh
iOS does **not** expose real-time aperture/bokeh control during capture through AVFoundation. However:

### AVDepthData (Reading Depth)
```swift
import AVFoundation

// Set up depth data output
let depthOutput = AVCaptureDepthDataOutput()
depthOutput.isFilteringEnabled = true // Smooths depth map

if session.canAddOutput(depthOutput) {
    session.addOutput(depthOutput)
    // Must use a device that supports depth (dual/triple/TrueDepth camera)
    // .builtInDualCamera, .builtInDualWideCamera, .builtInTrueDepthCamera
}

// Receive depth maps in delegate:
extension MyClass: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, 
                        didOutput depthData: AVDepthData, 
                        timestamp: CMTime, 
                        connection: AVCaptureConnection) {
        // depthData.depthDataMap is a CVPixelBuffer with per-pixel depth
        // depthData.depthDataType — kCVPixelFormatType_DisparityFloat16 or Float32
        let depthMap = depthData.depthDataMap
        // Use this to create custom bokeh effects in post-processing
    }
}
```

### AVPortraitEffectsMatte (iOS 12+)
```swift
// During photo capture, request portrait effects matte
let photoSettings = AVCapturePhotoSettings()
photoSettings.isPortraitEffectsMatteDeliveryEnabled = true

// In the delegate:
func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    if let matte = photo.portraitEffectsMatte {
        // matte.mattingImage — the bokeh/depth mask
        // Can be used with Core Image to apply custom bokeh
    }
}
```

### Custom Bokeh via Core Image + Depth Map
```swift
func applyBokeh(to image: CIImage, depthMap: CIImage, aperture: Float) -> CIImage? {
    // CIMaskedVariableBlur uses depth map to vary blur intensity
    let filter = CIFilter(name: "CIMaskedVariableBlur")!
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(depthMap, forKey: "inputMask")
    filter.setValue(aperture * 20, forKey: "inputRadius") // aperture controls blur amount
    return filter.outputImage
}
```

### Programmatic "Aperture" Control
Apple's Camera app lets you adjust the f-stop in Portrait mode (since iPhone XS), but this is done through **AVCapturePhotoOutput** settings:

```swift
// For photo capture with depth effect
let photoOutput = AVCapturePhotoOutput()
photoOutput.isDepthDataDeliveryEnabled = true
photoOutput.isPortraitEffectsMatteDeliveryEnabled = true

// The depth effect (bokeh strength) is controlled by:
// - maxPhotoQualityPrioritization
// - The depth data itself
// There is no direct "f-stop" API in AVFoundation
// Apple's adjustable bokeh is a Photos framework / editing feature
```

### Adjustable Depth in Photos Framework
After capture, the depth effect can be adjusted:
```swift
import Photos
import PhotosUI

// PHContentEditingInput provides the depth data
// You can re-render with different "aperture" values in post
// This is how the Photos app "edit depth" slider works
```

**Bottom line:** You cannot change "virtual aperture/f-stop" in real-time during recording via a public API. You can:
1. Capture depth data alongside video
2. Apply custom bokeh effects in real-time using the depth map + Core Image/Metal
3. Adjust the blur radius to simulate aperture changes

---

## 10. Cinematic Mode & iOS 17/18/26 APIs

### Cinematic Mode (iOS 15+)
Cinematic Mode was introduced in **iPhone 13** (2021). It records video with depth-of-field effects and **automatic rack focus** between subjects.

**Key fact: There is NO public API for Cinematic Mode recording.** As of iOS 18, Cinematic Mode is exclusively available through the built-in Camera app. Apple has not exposed an AVFoundation API to trigger cinematic video recording in third-party apps.

### Reading Cinematic Mode Videos (iOS 16+)
While you can't _record_ cinematic video, you can **read and edit** cinematic videos captured by the Camera app:

```swift
import Cinematic  // Framework introduced iOS 17

// Load a cinematic video asset
let asset = AVURLAsset(url: cinematicVideoURL)

// CinematicRenderPipeline (iOS 17+)
// Allows re-rendering with different focus points and aperture
if #available(iOS 17, *) {
    let cinematicAsset = try await CNAssetInfo(asset: asset)
    
    // Access the cinematic script (focus decisions)
    let script = try await CNScript(asset: cinematicAsset)
    
    // Get focus decisions at specific times
    let decisions = script.decisions(in: CMTimeRange(...))
    
    // Change focus to a different subject
    let detections = script.detections(in: someTimeRange)
    for detection in detections {
        // detection.focusDisparity — how sharp this subject is
        // You can add/remove focus decisions
    }
    
    // Re-render with custom focus and aperture
    let renderer = CNRenderingSession(
        commandQueue: metalCommandQueue,
        sessionAttributes: cinematicAsset.cinematicRenderingSessionAttributes
    )
    // renderer.render() with custom f-number
}
```

### iOS 17 Camera APIs
- **`AVCaptureDevice.isVirtualDevice`** — check if device is a virtual multi-lens device
- **`virtualDeviceSwitchOverVideoZoomFactors`** — zoom points where lens switching occurs
- **Zero Shutter Lag** improvements (faster photo capture)
- **Deferred photo processing** — `AVCapturePhotoOutput.captureReadiness`

### iOS 18 Camera APIs
- **Camera Control button** integration (`AVCaptureEventInteraction`)
- **Spatial video** on iPhone 15 Pro (for Vision Pro viewing)
- **LockedCameraCapture** framework — capture from Lock Screen
- **Improved `AVCaptureReaction`** — response to hand gestures (thumbs up = fireworks etc.) during FaceTime

```swift
// iOS 18: Camera Control button events
if #available(iOS 18, *) {
    let interaction = AVCaptureEventInteraction { event in
        // Primary event (light press)
        switch event.phase {
        case .began: print("Camera control pressed")
        case .ended: capturePhoto()
        default: break
        }
    } secondary: { event in
        // Hard press — custom action (e.g., switch lens)
        switchToNextLens()
    }
    view.addInteraction(interaction)
}
```

### iOS 26 (Expected - WWDC 2025)
Based on current trends and Apple's trajectory:
- **Apple Foundation Models** framework for on-device AI (confirmed in our CameraKit)
- **Enhanced Cinematic API** — possible public API for cinematic recording (speculative)
- **Spatial video improvements** — wider device support
- **ProRes Log recording API** — possible expansion beyond iPhone 15 Pro
- **LiDAR-enhanced depth** — better real-time depth for AR/video

### Relevant Existing Frameworks Summary

| Framework | What It Does | iOS Version |
|-----------|-------------|-------------|
| `AVFoundation` | Camera capture, recording, processing | iOS 4+ |
| `AVCaptureMultiCamSession` | Multi-camera simultaneous capture | iOS 13+ |
| `Cinematic` | Read/edit Cinematic Mode videos | iOS 17+ |
| `Vision` | Face/body/hand detection for auto-focus targets | iOS 11+ |
| `ARKit` | Depth, face tracking, world tracking | iOS 11+ |
| `Core Image` | Real-time image filters, depth-based effects | iOS 5+ |
| `Metal` | GPU compositing, custom render pipelines | iOS 8+ |

---

## Integration Recommendations for CameraKit

### Priority 1: Smooth Zoom (Easy Win)
Add `rampToVideoZoomFactor` to existing `CameraService`:

```swift
// Add to CameraService.swift
public func animateZoom(to factor: CGFloat, rate: Float = 2.0) {
    guard let device = currentVideoDevice else { return }
    let clamped = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
    do {
        try device.lockForConfiguration()
        device.ramp(toVideoZoomFactor: clamped, withRate: rate)
        device.unlockForConfiguration()
    } catch {
        print("CameraKit: Animated zoom error: \(error)")
    }
}

public func cancelZoomAnimation() {
    guard let device = currentVideoDevice else { return }
    do {
        try device.lockForConfiguration()
        device.cancelVideoZoomRamp()
        device.unlockForConfiguration()
        currentZoom = device.videoZoomFactor
    } catch {}
}
```

### Priority 2: Focus Pull Animation (Easy Win)
Add rack focus to existing `CameraService`:

```swift
public func animateFocusTo(lensPosition: Float) {
    guard let device = currentVideoDevice,
          device.isLockingFocusWithCustomLensPositionSupported else { return }
    do {
        try device.lockForConfiguration()
        device.setFocusModeLocked(lensPosition: max(0, min(1, lensPosition)))
        device.unlockForConfiguration()
    } catch {
        print("CameraKit: Focus animation error: \(error)")
    }
}
```

### Priority 3: Multi-Cam PiP (Medium Effort)
Create a new `MultiCamService` alongside existing `CameraService`. The two should share protocols but have different session types. This is a larger feature (~500-800 lines).

### Priority 4: Depth/Bokeh Effects (High Effort)
Requires depth-capable device detection, `AVCaptureDepthDataOutput` setup, and Core Image or Metal compositing pipeline. Best suited for a dedicated `DepthEffectsService`.

---

## Apple Sample Code References
- **AVMultiCamPiP** — Apple's official multi-cam PiP sample
- **AVCam** — Camera capture fundamentals
- **AVCamFilter** — Real-time camera filters with Metal
- **TrueDepthStreamer** — Depth data streaming from TrueDepth camera
- **Reading Cinematic Video Scripts** — Cinematic framework usage
