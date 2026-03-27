// Apple Foundation Models integration for CameraKit.
// Provides Tool protocol implementations that work with LanguageModelSession.
// Requires iOS 26+ / macOS 26+ with Apple Intelligence enabled.

#if canImport(FoundationModels) && os(iOS)
import Foundation
import FoundationModels
import UIKit
import AVFoundation
import os.log

private let agentLog = Logger(subsystem: "com.intento.app", category: "CameraAgent")

// MARK: - Individual Camera Tools (model-friendly naming)

// Apple's on-device model works better with individual tool names rather than
// a single "camera_action" tool with an action parameter. These separate tools
// match the names the model naturally generates.

@available(iOS 26.0, macOS 26.0, *)
public struct StartRecordingTool: Tool {
    public let name = "start_recording"
    public let description = "Start recording video with the camera."

    @Generable
    public struct Arguments: Sendable {
        // No arguments needed
    }

    let camera: CameraService

    public init(camera: CameraService) { self.camera = camera }

    public func call(arguments: Arguments) async throws -> String {
        print("[StartRecordingTool] Starting recording")
        // Give the session time to settle after any recent reconfiguration
        try? await Task.sleep(for: .milliseconds(500))
        let cam = camera
        let url = await MainActor.run { cam.startRecording() }
        print("[StartRecordingTool] Result: \(url != nil ? "started" : "failed")")
        if url != nil {
            // Auto-wait 3 seconds for minimum clip length
            print("[StartRecordingTool] Auto-waiting 3 seconds for minimum clip length...")
            try? await Task.sleep(for: .seconds(3))
            return "Recording started and has been running for 3 seconds. You can call stop_recording now, or wait longer for a longer clip."
        } else {
            return "Failed to start recording"
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
public struct StopRecordingTool: Tool {
    public let name = "stop_recording"
    public let description = "Stop recording video. Returns the filename of the recorded clip."

    @Generable
    public struct Arguments: Sendable {
        // No arguments needed
    }

    let camera: CameraService

    public init(camera: CameraService) { self.camera = camera }

    public func call(arguments: Arguments) async throws -> String {
        print("[StopRecordingTool] Stopping recording")
        let cam = camera
        let url: URL? = await cam.stopRecording()
        return url != nil ? "Recording stopped: \(url!.lastPathComponent)" : "No recording active"
    }
}

@available(iOS 26.0, macOS 26.0, *)
public struct CapturePhotoTool: Tool {
    public let name = "capture_photo"
    public let description = "Capture a single photo from the camera."

    @Generable
    public struct Arguments: Sendable {
        // No arguments needed
    }

    let camera: CameraService

    public init(camera: CameraService) { self.camera = camera }

    public func call(arguments: Arguments) async throws -> String {
        print("[CapturePhotoTool] Capturing photo")
        let cam = camera
        let image: UIImage? = await cam.capturePhoto()
        return image != nil ? "Photo captured" : "Failed to capture photo"
    }
}

@available(iOS 26.0, macOS 26.0, *)
public struct ConfigureCameraTool: Tool {
    public let name = "configure_camera"
    public let description = """
    Configure camera settings. Set position (front/back), lens (wide/ultraWide/telephoto), \
    zoom (1.0=normal, 2.0=2x), exposure (-2.0 to +2.0 EV), flash (off/on/auto/torch).
    """

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Camera position: front or back")
        var position: String?

        @Guide(description: "Lens type: wide, ultraWide, telephoto")
        var lens: String?

        @Guide(description: "Zoom level (1.0 = normal)")
        var zoom: Double?

        @Guide(description: "Exposure compensation (-2.0 to +2.0)")
        var exposure: Double?

        @Guide(description: "Flash mode: off, on, auto, torch")
        var flash: String?
    }

    let camera: CameraService

    public init(camera: CameraService) { self.camera = camera }

    public func call(arguments: Arguments) async throws -> String {
        print("[ConfigureCameraTool] Configuring camera")
        let cam = camera
        var applied: [String] = []

        if let pos = arguments.position {
            let position: AVCaptureDevice.Position = pos == "front" ? .front : .back
            let lens = arguments.lens.flatMap { CameraService.LensType(rawValue: $0) } ?? .wide
            await MainActor.run { cam.setCamera(position: position, lens: lens) }
            applied.append("\(pos) camera, \(lens.rawValue) lens")
        }

        if let z = arguments.zoom {
            await MainActor.run { cam.setZoom(CGFloat(z)) }
            applied.append("zoom \(String(format: "%.1f", z))x")
        }

        if let e = arguments.exposure {
            await MainActor.run { cam.setExposure(Float(e)) }
            applied.append("exposure \(String(format: "%+.1f", e)) EV")
        }

        if let f = arguments.flash, let mode = CameraService.FlashMode(rawValue: f) {
            await MainActor.run { cam.setFlash(mode) }
            applied.append("flash \(f)")
        }

        // Give AVCaptureSession time to stabilize after reconfiguration
        if !applied.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }

        return applied.isEmpty ? "No settings changed" : "Configured: \(applied.joined(separator: ", "))"
    }
}

// MARK: - Analyze Frame Tool (unified vision analysis)

/// Ultra-compact vision: runs all analysis (scene, faces, pose, horizon, blur, composition) in one call.
@available(iOS 26.0, macOS 26.0, *)
public struct AnalyzeFrameTool: Tool {
    public let name = "analyze_frame"
    public let description = """
    Analyze what the camera currently sees using on-device Vision AI. Returns: scene labels, \
    detected faces (count, positions, orientation), body poses, shot type (close-up/medium/wide), \
    scene type (talking head/interview/vlog/landscape), horizon level, image sharpness, \
    composition score, and detected rectangles. This is your primary way to "see" the scene.
    """

    @Generable
    public struct Arguments: Sendable {
        // No arguments — always analyzes current frame
    }

    let camera: CameraService
    let analyzer: SceneAnalyzer

    public init(camera: CameraService, analyzer: SceneAnalyzer) {
        self.camera = camera
        self.analyzer = analyzer
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[AnalyzeFrameTool] call() invoked")
        let sendableBuf: SendablePixelBuffer? = await MainActor.run {
            if let buf = camera.latestPixelBuffer {
                return SendablePixelBuffer(buffer: buf)
            }
            return nil
        }
        guard let sendableBuf else {
            print("[AnalyzeFrameTool] No camera frame available!")
            return "No camera frame available. Camera may still be starting."
        }
        print("[AnalyzeFrameTool] Got pixel buffer, analyzing...")

        let scene = await analyzer.analyze(pixelBuffer: sendableBuf.buffer)
        let faces = await analyzer.detectFaces(pixelBuffer: sendableBuf.buffer)
        let poses = await analyzer.detectPoses(pixelBuffer: sendableBuf.buffer)
        let horizon = await analyzer.detectHorizon(pixelBuffer: sendableBuf.buffer)
        let blur = await analyzer.detectBlur(pixelBuffer: sendableBuf.buffer)

        var parts: [String] = []

        if let scene {
            parts.append("Scene: \(scene.sceneLabels.prefix(5).joined(separator: ", "))")
            parts.append("Lighting: \(scene.lighting.rawValue)")
        }

        let shotType = await MainActor.run { analyzer.classifyShotType(faces: faces) }
        parts.append("Shot: \(shotType.rawValue)")

        if let scene {
            let sceneType = await MainActor.run { analyzer.classifySceneType(scene: scene, faces: faces, poses: poses) }
            parts.append("Type: \(sceneType.rawValue)")
        }

        parts.append("Faces: \(faces.count)")
        for (i, face) in faces.prefix(3).enumerated() {
            var desc = "Face\(i+1) at (\(String(format: "%.2f", face.boundingBox.midX)),\(String(format: "%.2f", face.boundingBox.midY)))"
            if let yaw = face.yaw {
                desc += yaw < -0.2 ? " looking-right" : yaw > 0.2 ? " looking-left" : " facing-camera"
            }
            parts.append(desc)
        }

        parts.append("Poses: \(poses.count)")
        parts.append("Level: \(horizon.isLevel ? "yes" : "no") (\(String(format: "%.1f", horizon.angle))°)")
        parts.append("Sharp: \(blur.isSharp ? "yes" : "no") (\(String(format: "%.2f", blur.sharpness)))")

        if let scene, !faces.isEmpty {
            let comp = await MainActor.run { analyzer.evaluateComposition(scene: scene, faces: faces, poses: poses) }
            parts.append("Composition: \(String(format: "%.0f%%", comp.overallScore * 100)) — \(comp.feedback)")
        }

        return parts.joined(separator: "\n")
    }
}

// MARK: - Speak Tool

@available(iOS 26.0, macOS 26.0, *)
public struct SpeakTool: Tool {
    public let name = "speak"
    public let description = "Speak a message aloud to the user via text-to-speech."

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "The message to speak aloud")
        var message: String
    }

    let voice: VoiceOutput

    public init(voice: VoiceOutput = VoiceOutput()) {
        self.voice = voice
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[SpeakTool] Speaking: \(arguments.message)")
        await MainActor.run { voice.speak(arguments.message) }
        return "Speaking: \"\(arguments.message)\""
    }
}

// MARK: - Listen Tool

@available(iOS 26.0, macOS 26.0, *)
public struct ListenTool: Tool {
    public let name = "listen"
    public let description = "Listen to the user's speech. Returns transcribed text."

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Seconds to listen (default 5)")
        var duration: Int?
    }

    let voiceInput: VoiceInput

    public init(voiceInput: VoiceInput) {
        self.voiceInput = voiceInput
    }

    public func call(arguments: Arguments) async throws -> String {
        let d = TimeInterval(arguments.duration ?? 5)
        let text = await voiceInput.listen(duration: d)
        return text.isEmpty ? "(silence — no speech detected)" : "User said: \"\(text)\""
    }
}

// MARK: - Wait Tool

@available(iOS 26.0, macOS 26.0, *)
public struct WaitTool: Tool {
    public let name = "wait"
    public let description = "Wait for specified seconds (1-30)."

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Seconds to wait")
        var seconds: Int
    }

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        let s = min(30, max(1, arguments.seconds))
        try? await Task.sleep(for: .seconds(s))
        return "Waited \(s) seconds."
    }
}

// MARK: - Send Response Tool

/// Allows the model to signal completion with a final message.
/// Apple Intelligence often generates a "send_response" tool call to wrap up.
@available(iOS 26.0, macOS 26.0, *)
public struct SendResponseTool: Tool {
    public let name = "send_response"
    public let description = "Send a final response message to the user when you are done with all tasks."

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "The final message to send to the user")
        var message: String
    }

    /// Callback to deliver the response.
    let onResponse: @Sendable (String) -> Void

    public init(onResponse: @escaping @Sendable (String) -> Void) {
        self.onResponse = onResponse
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[SendResponseTool] Final message: \(arguments.message)")
        onResponse(arguments.message)
        return "Response sent."
    }
}

// MARK: - Face Expression Tool

@available(iOS 26.0, macOS 26.0, *)
public struct DetectFacesTool: Tool {
    public let name = "detect_faces"
    public let description = """
    Detect faces with detailed expressions. Returns: face count, positions, \
    expressions (smiling, eyes closed, winking, mouth open), and gaze direction \
    (looking left/right/at camera). Also detects animals (cats, dogs).
    """

    @Generable
    public struct Arguments: Sendable {
        // No arguments — analyzes current frame
    }

    let camera: CameraService
    let analyzer: SceneAnalyzer

    public init(camera: CameraService, analyzer: SceneAnalyzer) {
        self.camera = camera
        self.analyzer = analyzer
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[DetectFacesTool] call() invoked")
        let sendableBuf: SendablePixelBuffer? = await MainActor.run {
            if let buf = camera.latestPixelBuffer {
                return SendablePixelBuffer(buffer: buf)
            }
            return nil
        }
        guard let sendableBuf else {
            return "No camera frame available."
        }

        let faces = await analyzer.detectFaceExpressions(pixelBuffer: sendableBuf.buffer)
        let animals = await analyzer.detectAnimals(pixelBuffer: sendableBuf.buffer)

        var parts: [String] = []

        if faces.isEmpty && animals.isEmpty {
            return "No faces or animals detected in frame."
        }

        parts.append("Faces: \(faces.count)")
        for (i, face) in faces.prefix(5).enumerated() {
            let pos = "(\(String(format: "%.2f", face.boundingBox.midX)),\(String(format: "%.2f", face.boundingBox.midY)))"
            parts.append("  Face\(i+1) at \(pos): \(face.expressionDescription)")
        }

        if !animals.isEmpty {
            parts.append("Animals: \(animals.count)")
            for animal in animals.prefix(3) {
                let pos = "(\(String(format: "%.2f", animal.boundingBox.midX)),\(String(format: "%.2f", animal.boundingBox.midY)))"
                parts.append("  \(animal.label) at \(pos) (confidence: \(String(format: "%.0f%%", animal.confidence * 100)))")
            }
        }

        return parts.joined(separator: "\n")
    }
}

// MARK: - Body Tracking Tool

@available(iOS 26.0, macOS 26.0, *)
public struct TrackBodyTool: Tool {
    public let name = "track_body"
    public let description = """
    Track human body poses. Returns skeleton joint positions (head, shoulders, \
    elbows, wrists, hips, knees, ankles) and body posture (standing, sitting, \
    arms raised, etc.). Useful for directing poses and movements.
    """

    @Generable
    public struct Arguments: Sendable {
        // No arguments — tracks current frame
    }

    let camera: CameraService
    let analyzer: SceneAnalyzer

    public init(camera: CameraService, analyzer: SceneAnalyzer) {
        self.camera = camera
        self.analyzer = analyzer
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[TrackBodyTool] call() invoked")
        let sendableBuf: SendablePixelBuffer? = await MainActor.run {
            if let buf = camera.latestPixelBuffer {
                return SendablePixelBuffer(buffer: buf)
            }
            return nil
        }
        guard let sendableBuf else {
            return "No camera frame available."
        }

        let poses = await analyzer.detectPoses(pixelBuffer: sendableBuf.buffer)

        if poses.isEmpty {
            return "No human bodies detected in frame."
        }

        var parts: [String] = []
        parts.append("Bodies detected: \(poses.count)")

        for (i, pose) in poses.prefix(3).enumerated() {
            parts.append("  Person \(i+1) (confidence: \(String(format: "%.0f%%", pose.confidence * 100))):")

            // Describe posture
            let headY = pose.joints["head_joint"]?.y ?? 0
            let hipY = pose.joints["hip_joint"]?.y ?? 0
            let rWristY = pose.joints["right_wrist_joint"]?.y ?? 0
            let lWristY = pose.joints["left_wrist_joint"]?.y ?? 0
            let rShoulderY = pose.joints["right_shoulder_joint"]?.y ?? 0
            let lShoulderY = pose.joints["left_shoulder_joint"]?.y ?? 0

            var posture: [String] = []
            if rWristY > rShoulderY || lWristY > lShoulderY { posture.append("arms raised") }
            if headY > 0.7 { posture.append("standing tall") }
            else if headY > 0.5 { posture.append("standing") }
            else { posture.append("sitting/crouching") }

            parts.append("    Posture: \(posture.isEmpty ? "neutral" : posture.joined(separator: ", "))")

            // Key joints
            let keyJoints = ["head_joint", "right_wrist_joint", "left_wrist_joint", "hip_joint"]
            for jointName in keyJoints {
                if let point = pose.joints[jointName] {
                    let name = jointName.replacingOccurrences(of: "_joint", with: "")
                    parts.append("    \(name): (\(String(format: "%.2f", point.x)),\(String(format: "%.2f", point.y)))")
                }
            }
        }

        return parts.joined(separator: "\n")
    }
}

// MARK: - Environment Description Tool

@available(iOS 26.0, macOS 26.0, *)
public struct DescribeEnvironmentTool: Tool {
    public let name = "describe_environment"
    public let description = "Detailed scene analysis — objects, lighting, faces, composition."

    @Generable
    public struct Arguments: Sendable {
        // No arguments — analyzes current frame
    }

    let camera: CameraService
    let analyzer: SceneAnalyzer

    public init(camera: CameraService, analyzer: SceneAnalyzer) {
        self.camera = camera
        self.analyzer = analyzer
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[DescribeEnvironmentTool] call() invoked")
        let sendableBuf: SendablePixelBuffer? = await MainActor.run {
            if let buf = camera.latestPixelBuffer {
                return SendablePixelBuffer(buffer: buf)
            }
            return nil
        }
        guard let sendableBuf else {
            return "No camera frame available."
        }

        let env = await analyzer.describeEnvironment(pixelBuffer: sendableBuf.buffer)
        // Compact output to save context tokens
        var parts: [String] = []
        parts.append("Scene: \(env.sceneLabels.prefix(3).joined(separator: ", "))")
        parts.append("Light: \(env.lighting.rawValue)")
        if env.faceCount > 0 { parts.append("Faces: \(env.faceCount)") }
        if env.animalCount > 0 { parts.append("Animals: \(env.animalTypes.joined(separator: ", "))") }
        parts.append("\(env.composition). Sharp:\(env.isSharp ? "y" : "n") Level:\(env.isLevel ? "y" : "n")")
        return parts.joined(separator: ". ")
    }
}

// MARK: - Scan Environment Tool (ARKit + Front/Back)

@available(iOS 26.0, macOS 26.0, *)
public struct ScanEnvironmentTool: Tool {
    public let name = "scan_environment"
    public let description = "3D scan using ARKit — planes, depth, lighting, plus front+back camera views."

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Whether to also capture and analyze the front camera view. Default true for full understanding.")
        var includeFrontCamera: Bool?
    }

    let camera: CameraService
    let analyzer: SceneAnalyzer

    public init(camera: CameraService, analyzer: SceneAnalyzer) {
        self.camera = camera
        self.analyzer = analyzer
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[ScanEnvironmentTool] Starting comprehensive environment scan")
        agentLog.notice("[ScanEnvironmentTool] Starting comprehensive environment scan")
        var parts: [String] = []
        let includeFront = arguments.includeFrontCamera ?? true

        // Step 1: Analyze current back camera frame (2D Vision analysis)
        let backBuf: SendablePixelBuffer? = await MainActor.run {
            if let buf = camera.latestPixelBuffer {
                return SendablePixelBuffer(buffer: buf)
            }
            return nil
        }
        if let backBuf {
            let env = await analyzer.describeEnvironment(pixelBuffer: backBuf.buffer)
            // Compact: just scene + lighting + key details
            var backParts: [String] = []
            backParts.append("Back: \(env.sceneLabels.prefix(3).joined(separator: ", ")), \(env.lighting.rawValue) light")
            if env.faceCount > 0 { backParts.append("\(env.faceCount) faces") }
            if env.animalCount > 0 { backParts.append("\(env.animalTypes.joined(separator: ", "))") }
            if !env.recognizedTexts.isEmpty { backParts.append("text: \(env.recognizedTexts.prefix(2).joined(separator: ", "))") }
            backParts.append(env.composition)
            parts.append(backParts.joined(separator: ". "))
        }

        // Step 2: ARKit 3D scan (back camera)
        #if canImport(ARKit) && !targetEnvironment(simulator)
        let arSupported = await MainActor.run { ARSceneUnderstanding.isSupported }
        if arSupported {
            let arScene = await MainActor.run { ARSceneUnderstanding() }
            
            // Pause AVCaptureSession to free the camera for ARKit
            await MainActor.run { camera.stopSession() }
            
            let snapshot = await arScene.scan(duration: 3.0)
            
            // Resume AVCaptureSession
            await MainActor.run { camera.startSession() }
            
            // Compact ARKit summary
            var arParts: [String] = []
            if !snapshot.planes.isEmpty {
                let grouped = Dictionary(grouping: snapshot.planes, by: { $0.classification })
                let surfaceList = grouped.map { "\($0.key)(\($0.value.count))" }.joined(separator: ", ")
                arParts.append("3D: \(surfaceList)")
            }
            arParts.append("\(Int(snapshot.ambientIntensityLumens))lm \(Int(snapshot.colorTemperatureKelvin))K")
            if let d = snapshot.depthRangeMeters {
                arParts.append("depth \(String(format: "%.1f", d.min))-\(String(format: "%.1f", d.max))m")
            }
            // Room estimate
            let floors = snapshot.planes.filter { $0.classification == "floor" }
            let ceilings = snapshot.planes.filter { $0.classification == "ceiling" }
            if let floor = floors.first {
                var room = "room ~\(String(format: "%.0f", floor.widthMeters))×\(String(format: "%.0f", floor.heightMeters))m"
                if let ceil = ceilings.first {
                    let h = ceil.centerPosition.y - floor.centerPosition.y
                    if h > 0.5 { room += " h=\(String(format: "%.1f", h))m" }
                }
                arParts.append(room)
            }
            parts.append(arParts.joined(separator: ". "))
        }
        #endif

        // Step 3: Switch to front camera and analyze
        if includeFront {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run { camera.switchToFrontCamera() }
            try? await Task.sleep(for: .milliseconds(800))
            
            let frontBuf: SendablePixelBuffer? = await MainActor.run {
                if let buf = camera.latestPixelBuffer {
                    return SendablePixelBuffer(buffer: buf)
                }
                return nil
            }
            if let frontBuf {
                let frontEnv = await analyzer.describeEnvironment(pixelBuffer: frontBuf.buffer)
                var frontParts: [String] = []
                frontParts.append("Front: \(frontEnv.sceneLabels.prefix(3).joined(separator: ", "))")
                if frontEnv.faceCount > 0 { frontParts.append("\(frontEnv.faceCount) faces, \(frontEnv.faceExpressions.prefix(2).joined(separator: "; "))") }
                parts.append(frontParts.joined(separator: ". "))
            }
            
            await MainActor.run { camera.switchToBackCamera() }
        }

        print("[ScanEnvironmentTool] Scan complete")
        agentLog.notice("[ScanEnvironmentTool] Scan complete, parts: \(parts.count)")
        return parts.joined(separator: "\n")
    }
}

// MARK: - Smooth Zoom Tool

@available(iOS 26.0, macOS 26.0, *)
public struct SmoothZoomTool: Tool {
    public let name = "smooth_zoom"
    public let description = """
    Smoothly animate zoom to a target level over time. Creates cinematic zoom effects. \
    target: zoom level (1.0 = normal, 2.0 = 2x, etc.). duration: seconds for the animation.
    """

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Target zoom level (1.0-5.0)")
        var target: Double

        @Guide(description: "Animation duration in seconds (0.5-5.0)")
        var duration: Double?
    }

    let camera: CameraService

    public init(camera: CameraService) { self.camera = camera }

    public func call(arguments: Arguments) async throws -> String {
        print("[SmoothZoomTool] Zooming to \(arguments.target) over \(arguments.duration ?? 1.0)s")
        let targetZoom = max(1.0, min(5.0, CGFloat(arguments.target)))
        let duration = max(0.3, min(5.0, arguments.duration ?? 1.0))
        let steps = Int(duration * 60) // 60 fps
        let cam = camera

        let currentZoom = await MainActor.run { cam.currentZoom }
        let delta = (targetZoom - currentZoom) / CGFloat(steps)

        for step in 0..<steps {
            let newZoom = currentZoom + delta * CGFloat(step + 1)
            await MainActor.run {
                cam.setZoom(newZoom)
            }
            try? await Task.sleep(for: .milliseconds(Int(1000.0 / 60.0)))
        }

        return "Zoom animated from \(String(format: "%.1f", currentZoom))x to \(String(format: "%.1f", targetZoom))x over \(String(format: "%.1f", duration))s"
    }
}

// MARK: - Overlay Tool

@available(iOS 26.0, macOS 26.0, *)
public struct AddOverlayTool: Tool {
    public let name = "add_overlay"
    public let description = """
    Add a text or emoji overlay on the camera preview. \
    text: the text/emoji to display. \
    position: where to place it (top, center, bottom, top-left, top-right, bottom-left, bottom-right). \
    size: font size (small, medium, large). \
    color: text color (white, black, red, yellow, green, blue).
    """

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Text or emoji to display as overlay")
        var text: String

        @Guide(description: "Position: top, center, bottom, top-left, top-right, bottom-left, bottom-right")
        var position: String?

        @Guide(description: "Size: small, medium, large")
        var size: String?

        @Guide(description: "Color: white, black, red, yellow, green, blue")
        var color: String?
    }

    let onOverlay: @Sendable (String, String, String, String) -> Void

    public init(onOverlay: @escaping @Sendable (String, String, String, String) -> Void) {
        self.onOverlay = onOverlay
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[AddOverlayTool] Adding overlay: \(arguments.text) at \(arguments.position ?? "center")")
        onOverlay(
            arguments.text,
            arguments.position ?? "center",
            arguments.size ?? "large",
            arguments.color ?? "white"
        )
        return "Overlay added: \"\(arguments.text)\" at \(arguments.position ?? "center")"
    }
}

// MARK: - PiP Camera Tool

@available(iOS 26.0, macOS 26.0, *)
public struct TogglePiPTool: Tool {
    public let name = "toggle_pip"
    public let description = """
    Toggle Picture-in-Picture mode (dual camera). When enabled, both front and back \
    cameras record simultaneously — main camera fills the screen, secondary camera \
    appears as a small overlay. Great for vlog-style videos. \
    action: "enable" to turn on PiP, "disable" to turn off, "swap" to switch which \
    camera is main vs overlay, "move" to change overlay position.
    """

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Action: enable, disable, swap, move")
        var action: String

        @Guide(description: "PiP overlay position: top-left, top-right, bottom-left, bottom-right (only for action=move)")
        var position: String?
    }

    let onPiPAction: @Sendable (String, String?) -> Void

    public init(onPiPAction: @escaping @Sendable (String, String?) -> Void) {
        self.onPiPAction = onPiPAction
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[TogglePiPTool] Action: \(arguments.action), position: \(arguments.position ?? "nil")")
        onPiPAction(arguments.action, arguments.position)
        switch arguments.action {
        case "enable":
            return "PiP mode enabled! Front + back cameras recording simultaneously."
        case "disable":
            return "PiP mode disabled. Back to single camera."
        case "swap":
            return "Cameras swapped! Main and PiP views are now switched."
        case "move":
            return "PiP overlay moved to \(arguments.position ?? "top-right")."
        default:
            return "Unknown PiP action: \(arguments.action)"
        }
    }
}

// MARK: - Image Generation Tool

#if canImport(ImagePlayground)
import ImagePlayground

/// Generate stylized images from text descriptions using Apple Image Playground.
@available(iOS 26.0, macOS 26.0, *)
public struct GenerateImageFMTool: Tool {
    public let name = "generate_image"
    public let description = """
    Generate a stylized image from a text description. \
    Styles: animation (cartoon), illustration, sketch. \
    Can optionally use the current camera frame as source for style transfer.
    """

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Text description of the image to generate")
        var description: String

        @Guide(description: "Style: animation, illustration, or sketch")
        var style: String?

        @Guide(description: "If true, uses current camera frame as source")
        var use_camera_frame: Bool?
    }

    let camera: CameraService

    public init(camera: CameraService) {
        self.camera = camera
    }

    public func call(arguments: Arguments) async throws -> String {
        let creator = try await ImageCreator()

        var concepts: [ImagePlaygroundConcept] = [.text(arguments.description)]

        if arguments.use_camera_frame == true {
            let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                if let buf = camera.latestPixelBuffer {
                    return SendablePixelBuffer(buffer: buf)
                }
                return nil
            }
            if let sendableBuf {
                let ciImage = CIImage(cvPixelBuffer: sendableBuf.buffer)
                let context = CIContext()
                if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                    concepts.append(.image(cgImage))
                }
            }
        }

        let playgroundStyle: ImagePlaygroundStyle
        switch arguments.style ?? "animation" {
        case "illustration": playgroundStyle = .illustration
        case "sketch": playgroundStyle = .sketch
        default: playgroundStyle = .animation
        }

        for try await result in creator.images(for: concepts, style: playgroundStyle, limit: 1) {
            let filename = "generated_\(Int(Date().timeIntervalSince1970)).png"
            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = docsDir.appendingPathComponent(filename)
            if let data = UIImage(cgImage: result.cgImage).pngData() {
                try data.write(to: fileURL)
                return "Image generated: \(filename) (style: \(arguments.style ?? "animation"))"
            }
        }
        return "Image generation completed but no result received."
    }
}
#endif

// MARK: - Read Skill Tool

@available(iOS 26.0, macOS 26.0, *)
public struct ReadSkillTool: Tool {
    public let name = "read_skill"
    public let description = """
    Read a skill file to learn how to perform a specific task. \
    Available skills: free-bgm (download and add background music). \
    Call this when the user requests something covered by a skill.
    """

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Skill name, e.g. 'free-bgm' or 'index' to list all skills")
        var name: String
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[ReadSkillTool] Reading skill: \(arguments.name)")
        let skillName = arguments.name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Look for skill file in bundle — try subdirectory first, then root (iOS flattens resources)
        if let url = Bundle.main.url(forResource: skillName, withExtension: "md", subdirectory: "Skills") {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }
        
        // iOS often flattens resources to bundle root
        if let url = Bundle.main.url(forResource: skillName, withExtension: "md") {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }
        
        return "Skill '\(skillName)' not found. Available skills: free-bgm. Use read_skill(name: 'index') to list all skills."
    }
}

// MARK: - Web Browse Tool

/// Wraps a web browsing callback so the on-device AI can navigate, snapshot, click, type, download.
@available(iOS 26.0, macOS 26.0, *)
public struct WebBrowseTool: Tool {
    public let name = "web_browse"
    public let description = """
    Browse the web to find and download content. Commands: \
    navigate (go to URL), snapshot (scan page elements), click (click element by ref), \
    type (type text into input), download (download file by ref or URL).
    """

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Command: navigate, snapshot, click, type, download")
        var command: String
        
        @Guide(description: "URL for navigate or download commands")
        var url: String?
        
        @Guide(description: "Element ref from snapshot, e.g. 'r5'")
        var ref: String?
        
        @Guide(description: "Text to type")
        var text: String?
    }

    /// Callback to execute web commands. Returns result string.
    let onWebCommand: @Sendable (String, String?, String?, String?) async -> String

    public init(onWebCommand: @escaping @Sendable (String, String?, String?, String?) async -> String) {
        self.onWebCommand = onWebCommand
    }

    public func call(arguments: Arguments) async throws -> String {
        print("[WebBrowseTool] \(arguments.command) url=\(arguments.url ?? "nil") ref=\(arguments.ref ?? "nil")")
        return await onWebCommand(arguments.command, arguments.url, arguments.ref, arguments.text)
    }
}

// MARK: - Apple Camera Agent

/// Runs a camera director session using Apple's on-device Foundation Models.
/// Ultra-compact: 5 tools — camera_action, analyze_frame, speak, listen, wait.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class AppleCameraAgent {

    public let camera: CameraService
    public let analyzer: SceneAnalyzer
    public let voice: VoiceOutput
    public let voiceInput: VoiceInput

    /// Callback when agent sends a response.
    public var onResponse: (@Sendable (String) -> Void)?

    /// Callback for PiP actions.
    public var onPiPAction: (@Sendable (String, String?) -> Void)?

    /// Callback for overlay display.
    public var onOverlay: (@Sendable (String, String, String, String) -> Void)?

    /// Callback for web browsing commands.
    public var onWebCommand: (@Sendable (String, String?, String?, String?) async -> String)?

    public init(
        camera: CameraService,
        analyzer: SceneAnalyzer = SceneAnalyzer(),
        voice: VoiceOutput = VoiceOutput(),
        voiceInput: VoiceInput = VoiceInput(),
    ) {
        self.camera = camera
        self.analyzer = analyzer
        self.voice = voice
        self.voiceInput = voiceInput
    }

    /// Run the agent with a given prompt. Returns the final response.
    public func run(prompt: String, instructions: String? = nil) async throws -> String {
        let defaultInstructions = """
        You are a camera assistant. The user consented to all camera features.
        
        Tools: analyze_frame, describe_environment, scan_environment (3D/ARKit), \
        detect_faces, track_body, configure_camera, smooth_zoom, \
        start_recording, stop_recording, capture_photo, add_overlay, \
        toggle_pip, speak, listen, wait, send_response, read_skill, web_browse.
        
        Workflow: analyze_frame → speak greeting → configure → capture photos/video → send_response.
        Keep tool outputs short. Call send_response when done.
        """

        print("[AppleCameraAgent] Building tools...")
        agentLog.notice("[AppleCameraAgent] Building tools...")
        let responseCallback = onResponse
        let overlayCallback = onOverlay
        let pipCallback = onPiPAction
        let webCallback = onWebCommand
        var tools: [any Tool] = [
                StartRecordingTool(camera: camera),
                StopRecordingTool(camera: camera),
                CapturePhotoTool(camera: camera),
                ConfigureCameraTool(camera: camera),
                SmoothZoomTool(camera: camera),
                AnalyzeFrameTool(camera: camera, analyzer: analyzer),
                DescribeEnvironmentTool(camera: camera, analyzer: analyzer),
                ScanEnvironmentTool(camera: camera, analyzer: analyzer),
                DetectFacesTool(camera: camera, analyzer: analyzer),
                TrackBodyTool(camera: camera, analyzer: analyzer),
                AddOverlayTool(onOverlay: { text, pos, size, color in overlayCallback?(text, pos, size, color) }),
                TogglePiPTool(onPiPAction: { action, pos in pipCallback?(action, pos) }),
                SpeakTool(voice: voice),
                ListenTool(voiceInput: voiceInput),
                WaitTool(),
                SendResponseTool(onResponse: { msg in responseCallback?(msg) }),
                ReadSkillTool(),
            ]
        // Add web browsing if callback is provided
        if let webCallback {
            tools.append(WebBrowseTool(onWebCommand: { cmd, url, ref, text in
                await webCallback(cmd, url, ref, text)
            }))
        }
        print("[AppleCameraAgent] Tools built: \(tools.map { $0.name })")
        agentLog.notice("[AppleCameraAgent] Tools built: \(tools.map { $0.name }.joined(separator: ", "))")

        print("[AppleCameraAgent] Creating LanguageModelSession...")
        agentLog.notice("[AppleCameraAgent] Creating LanguageModelSession...")
        let session = LanguageModelSession(
            tools: tools,
            instructions: instructions ?? defaultInstructions
        )
        print("[AppleCameraAgent] Session created. Calling respond(to:)...")
        agentLog.notice("[AppleCameraAgent] Session created. Calling respond(to:)...")

        do {
            let response = try await session.respond(to: prompt)
            print("[AppleCameraAgent] Got response: \(response.content.prefix(200))")
            agentLog.notice("[AppleCameraAgent] Got response: \(response.content.prefix(200))")
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty || content == "null" || content == "nil" {
                let fallback = "Session complete! The AI director finished filming."
                onResponse?(fallback)
                return fallback
            }
            onResponse?(content)
            return content
        } catch {
            // Handle known FoundationModels errors gracefully
            let errorDesc = "\(error)"
            print("[AppleCameraAgent] Error during respond: \(errorDesc)")
            agentLog.error("[AppleCameraAgent] Error during respond: \(errorDesc)")

            // These errors happen when the model generates invalid tool calls
            // (wrong tool names like "send_response" or "camera_action").
            // The agent likely completed useful work before the error.
            let isRecoverable = errorDesc.contains("ToolCallError")
                || errorDesc.contains("decodingFailure")
                || errorDesc.contains("unrecognized name")
                || errorDesc.contains("deserialize")
                || errorDesc.contains("GenerationError")
                || errorDesc.contains("context window")
            
            if isRecoverable {
                let msg = "Session complete! The AI director finished its work."
                onResponse?(msg)
                return msg
            }
            throw error
        }
    }
}

#endif
