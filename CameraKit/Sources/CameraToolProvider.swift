#if os(iOS)
import Foundation
import UIKit
import AVFoundation
import CopilotSDK

#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Builds CopilotSDK ToolDefinitions backed by CameraKit services.
/// Each tool maps an AI agent's tool call to an iOS camera/voice/analysis API.
@MainActor
public final class CameraToolProvider {

    public let camera: CameraService
    public let voice: VoiceOutput
    public let voiceInput: VoiceInput
    public let analyzer: SceneAnalyzer

    // State tracking
    private var recordingStartTime: Date?
    private var shotCount = 0

    /// Camera animation engine for keyframed parameter changes.
    public private(set) lazy var animator = CameraAnimator(camera: camera)

    /// Callbacks for external event handling (e.g., UI updates).
    public var onRecordStart: (() -> Void)?
    public var onRecordStop: ((URL?, TimeInterval) -> Void)?
    public var onFinish: (() -> Void)?

    public init(
        camera: CameraService,
        voice: VoiceOutput = VoiceOutput(),
        voiceInput: VoiceInput = VoiceInput(),
        analyzer: SceneAnalyzer = SceneAnalyzer()
    ) {
        self.camera = camera
        self.voice = voice
        self.voiceInput = voiceInput
        self.analyzer = analyzer
    }

    // MARK: - Tool Builders

    /// All available camera tools.
    public var allTools: [ToolDefinition] {
        [
            observeCameraTool,
            sceneAnalysisTool,
            speakTool,
            listenTool,
            startRecordingTool,
            stopRecordingTool,
            pauseRecordingTool,
            resumeRecordingTool,
            capturePhotoTool,
            setCameraTool,
            setZoomTool,
            switchCameraTool,
            setExposureTool,
            setManualExposureTool,
            setFocusTool,
            setFlashTool,
            setWhiteBalanceTool,
            deviceInfoTool,
            detectObjectsTool,
            detectFacesTool,
            detectPoseTool,
            analyzeShotTool,
            detectHorizonTool,
            detectBlurTool,
            classifyShotTool,
            classifySceneTool,
            detectRectanglesTool,
            trackSubjectTool,
            setSlowMotionTool,
            getAudioLevelsTool,
            generateImageTool,
            animateCameraTool,
            waitTool,
        ]
    }

    /// Compact tool set — merges granular settings/vision into unified tools.
    /// Use this when you want fewer tools (reduces round-trips).
    /// - `configure_camera` replaces: set_camera, set_zoom, set_exposure, set_manual_exposure,
    ///   set_focus, set_flash, set_white_balance, switch_camera, get_device_info, set_slow_motion
    /// - `analyze_vision` replaces: detect_objects, detect_faces, detect_pose, get_scene_analysis,
    ///   analyze_shot, detect_horizon, detect_blur, classify_shot, classify_scene, detect_rectangles
    public var compactTools: [ToolDefinition] {
        [
            observeCameraTool,
            configureCameraTool,  // unified camera settings
            analyzeVisionTool,    // unified vision analysis
            speakTool,
            listenTool,
            startRecordingTool,
            stopRecordingTool,
            pauseRecordingTool,
            resumeRecordingTool,
            capturePhotoTool,
            trackSubjectTool,
            getAudioLevelsTool,
            generateImageTool,
            animateCameraTool,
            waitTool,
        ]
    }

    /// Get tools for a specific skill preset.
    public func tools(for skill: CameraSkill) -> [ToolDefinition] {
        skill.toolNames.compactMap { name in
            allTools.first { $0.name == name }
        }
    }

    /// Get compact tools for a specific skill preset (unified configure_camera + analyze_vision).
    public func compactTools(for skill: CameraSkill) -> [ToolDefinition] {
        let combined = allTools + [configureCameraTool, analyzeVisionTool]
        return skill.compactToolNames.compactMap { name in
            combined.first { $0.name == name }
        }
    }

    // MARK: - Observation Tools

    public var observeCameraTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "observe_camera",
            description: "Look through the camera. Returns a base64 JPEG image of the current view. Call this when you want to see what the camera sees.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            skipPermission: true,
            handler: { _ in
                let base64 = await MainActor.run { cam.getLatestFrameBase64(quality: 0.1) }
                if let base64 {
                    return "[IMAGE: data:image/jpeg;base64,\(base64)]"
                }
                return "No camera frame available yet. The camera may still be starting."
            }
        )
    }

    public var sceneAnalysisTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "get_scene_analysis",
            description: "Analyze the current camera frame using on-device Vision AI. Returns scene labels, detected text, lighting conditions, and focal points.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            skipPermission: true,
            handler: { _ in
                guard let context = await MainActor.run(body: { analyzer.latestContext }) else {
                    return "No scene analysis available yet. Try observe_camera first."
                }
                return """
                Scene: \(context.sceneLabels.joined(separator: ", "))
                Text detected: \(context.recognizedTexts.joined(separator: ", "))
                Lighting: \(context.lighting.rawValue)
                Aesthetic score: \(String(format: "%.1f", context.aestheticScore))/1.0
                Focal points: \(context.focalPoints.map { "(\(String(format: "%.2f", $0.x)), \(String(format: "%.2f", $0.y)))" }.joined(separator: ", "))
                """
            }
        )
    }

    // MARK: - Voice Tools

    public var speakTool: ToolDefinition {
        let voice = self.voice
        return ToolDefinition(
            name: "speak",
            description: "Speak a message aloud to the user via text-to-speech. Use this to give directions, encouragement, or instructions.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("The message to speak aloud"),
                    ]),
                ]),
                "required": .array([.string("message")]),
            ]),
            skipPermission: true,
            handler: { args in
                let message: String
                if case .object(let dict) = args, case .string(let msg) = dict["message"] {
                    message = msg
                } else if case .string(let msg) = args {
                    message = msg
                } else {
                    return "Error: no message provided"
                }
                await MainActor.run { voice.speak(message) }
                // Wait for speech to finish before returning so recording doesn't overlap
                while await MainActor.run(body: { voice.isSpeaking }) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return "Spoke: \"\(message)\""
            }
        )
    }

    public var listenTool: ToolDefinition {
        let input = self.voiceInput
        return ToolDefinition(
            name: "listen",
            description: "Listen to the user's speech for a given duration. Returns the transcribed text.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "duration": .object([
                        "type": .string("number"),
                        "description": .string("Seconds to listen (default 5)"),
                    ]),
                ]),
            ]),
            skipPermission: true,
            handler: { args in
                let duration: TimeInterval
                if case .object(let dict) = args, case .int(let d) = dict["duration"] {
                    duration = TimeInterval(d)
                } else if case .object(let dict) = args, case .double(let d) = dict["duration"] {
                    duration = d
                } else {
                    duration = 5.0
                }
                let text = await input.listen(duration: duration)
                return text.isEmpty ? "(silence — no speech detected)" : "User said: \"\(text)\""
            }
        )
    }

    // MARK: - Recording Tools

    public var startRecordingTool: ToolDefinition {
        let cam = camera
        let voiceOut = self.voice
        return ToolDefinition(
            name: "start_recording",
            description: "Start recording video. Returns the recording file path. Waits for any text-to-speech to finish first.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "shot_name": .object([
                        "type": .string("string"),
                        "description": .string("A name for this shot (optional)"),
                    ]),
                ]),
            ]),
            skipPermission: true,
            handler: { [weak self] args in
                // Wait for TTS to finish before recording (avoid speaker audio in video)
                while await MainActor.run(body: { voiceOut.isSpeaking }) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let shotName: String
                if case .object(let dict) = args, case .string(let name) = dict["shot_name"] {
                    shotName = name
                } else {
                    shotName = "Shot"
                }
                let (url, count) = await MainActor.run { () -> (URL?, Int) in
                    let u = cam.startRecording()
                    self?.recordingStartTime = Date()
                    self?.onRecordStart?()
                    let c = self?.shotCount ?? 0
                    return (u, c)
                }
                let name = shotName == "Shot" ? "Shot \(count + 1)" : shotName
                return url != nil
                    ? "Recording started: \(name)"
                    : "Failed to start recording (already recording or camera not ready)"
            }
        )
    }

    public var stopRecordingTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "stop_recording",
            description: "Stop the current video recording. Returns the duration and file path.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            skipPermission: true,
            handler: { [weak self] _ in
                let url: URL? = await cam.stopRecording()
                let duration = await MainActor.run { () -> TimeInterval in
                    let d: TimeInterval
                    if let start = self?.recordingStartTime {
                        d = Date().timeIntervalSince(start)
                    } else {
                        d = 0
                    }
                    self?.shotCount += 1
                    self?.recordingStartTime = nil
                    self?.onRecordStop?(url, d)
                    return d
                }
                if let url {
                    return "Recording stopped. Duration: \(String(format: "%.1f", duration))s, File: \(url.lastPathComponent)"
                }
                return "No recording was active."
            }
        )
    }

    public var capturePhotoTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "capture_photo",
            description: "Capture a still photo from the camera.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            skipPermission: true,
            handler: { _ in
                let image: UIImage? = await cam.capturePhoto()
                if image != nil {
                    return "Photo captured successfully."
                }
                return "Failed to capture photo."
            }
        )
    }

    // MARK: - Camera Control Tools

    public var setZoomTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "set_zoom",
            description: "Set the camera zoom level. 1.0 is normal, 2.0 is 2x zoom, etc.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "level": .object([
                        "type": .string("number"),
                        "description": .string("Zoom level (1.0 = normal, max varies by device)"),
                    ]),
                ]),
                "required": .array([.string("level")]),
            ]),
            skipPermission: true,
            handler: { args in
                let level: CGFloat
                if case .object(let dict) = args, case .double(let l) = dict["level"] {
                    level = CGFloat(l)
                } else if case .object(let dict) = args, case .int(let l) = dict["level"] {
                    level = CGFloat(l)
                } else {
                    return "Error: zoom level required"
                }
                await MainActor.run { cam.setZoom(level) }
                let actual = await MainActor.run { cam.currentZoom }
                return "Zoom set to \(String(format: "%.1f", actual))x"
            }
        )
    }

    public var switchCameraTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "switch_camera",
            description: "Switch between front and back camera.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            skipPermission: true,
            handler: { _ in
                await MainActor.run { cam.switchCamera() }
                let pos = await MainActor.run { cam.currentCameraPosition }
                return "Switched to \(pos == .front ? "front" : "back") camera"
            }
        )
    }

    public var setExposureTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "set_exposure",
            description: "Set exposure compensation. Range: -2.0 (darker) to +2.0 (brighter).",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "compensation": .object([
                        "type": .string("number"),
                        "description": .string("Exposure compensation in EV (-2.0 to +2.0)"),
                    ]),
                ]),
                "required": .array([.string("compensation")]),
            ]),
            skipPermission: true,
            handler: { args in
                let comp: Float
                if case .object(let dict) = args, case .double(let c) = dict["compensation"] {
                    comp = Float(c)
                } else if case .object(let dict) = args, case .int(let c) = dict["compensation"] {
                    comp = Float(c)
                } else {
                    return "Error: compensation value required"
                }
                await MainActor.run { cam.setExposure(comp) }
                return "Exposure set to \(String(format: "%+.1f", comp)) EV"
            }
        )
    }

    public var setFocusTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "set_focus",
            description: "Set focus point. Coordinates are normalized 0-1 (0,0 = top-left, 1,1 = bottom-right).",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("Horizontal position (0-1)")]),
                    "y": .object(["type": .string("number"), "description": .string("Vertical position (0-1)")]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ]),
            skipPermission: true,
            handler: { args in
                guard case .object(let dict) = args else { return "Error: x and y required" }
                let x: Float
                let y: Float
                if case .double(let xv) = dict["x"] { x = Float(xv) }
                else if case .int(let xv) = dict["x"] { x = Float(xv) }
                else { return "Error: x required" }
                if case .double(let yv) = dict["y"] { y = Float(yv) }
                else if case .int(let yv) = dict["y"] { y = Float(yv) }
                else { return "Error: y required" }
                await MainActor.run { cam.setFocus(x: x, y: y) }
                return "Focus set to (\(String(format: "%.2f", x)), \(String(format: "%.2f", y)))"
            }
        )
    }

    public var setFlashTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "set_flash",
            description: "Set flash/torch mode: 'off', 'on', 'auto', or 'torch' (continuous light).",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("off"), .string("on"), .string("auto"), .string("torch")]),
                        "description": .string("Flash mode"),
                    ]),
                ]),
                "required": .array([.string("mode")]),
            ]),
            skipPermission: true,
            handler: { args in
                let modeStr: String
                if case .object(let dict) = args, case .string(let m) = dict["mode"] {
                    modeStr = m
                } else {
                    return "Error: mode required (off/on/auto/torch)"
                }
                guard let mode = CameraService.FlashMode(rawValue: modeStr) else {
                    return "Error: invalid mode '\(modeStr)'. Use: off, on, auto, torch"
                }
                await MainActor.run { cam.setFlash(mode) }
                return "Flash set to \(modeStr)"
            }
        )
    }

    // MARK: - Timing

    public var waitTool: ToolDefinition {
        ToolDefinition(
            name: "wait",
            description: "Wait for a specified number of seconds. Use this to let things happen (e.g., let the user move, wait for recording duration).",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "seconds": .object([
                        "type": .string("number"),
                        "description": .string("Seconds to wait (1-30)"),
                    ]),
                ]),
                "required": .array([.string("seconds")]),
            ]),
            skipPermission: true,
            handler: { args in
                let seconds: TimeInterval
                if case .object(let dict) = args, case .int(let s) = dict["seconds"] {
                    seconds = min(30, max(1, TimeInterval(s)))
                } else if case .object(let dict) = args, case .double(let s) = dict["seconds"] {
                    seconds = min(30, max(1, s))
                } else {
                    seconds = 3
                }
                try? await Task.sleep(for: .seconds(seconds))
                return "Waited \(String(format: "%.0f", seconds)) seconds."
            }
        )
    }

    // MARK: - Enhanced Camera Controls

    public var setCameraTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "set_camera",
            description: "Set camera position and lens. Available lenses: 'wide' (default), 'ultraWide' (0.5x), 'telephoto' (3x). Position: 'front' or 'back'.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "position": .object([
                        "type": .string("string"),
                        "enum": .array([.string("front"), .string("back")]),
                        "description": .string("Camera position"),
                    ]),
                    "lens": .object([
                        "type": .string("string"),
                        "enum": .array([.string("wide"), .string("ultraWide"), .string("telephoto")]),
                        "description": .string("Lens type"),
                    ]),
                ]),
            ]),
            skipPermission: true,
            handler: { args in
                var position: AVCaptureDevice.Position?
                var lens: CameraService.LensType = .wide
                if case .object(let dict) = args {
                    if case .string(let p) = dict["position"] {
                        position = p == "front" ? .front : .back
                    }
                    if case .string(let l) = dict["lens"] {
                        lens = CameraService.LensType(rawValue: l) ?? .wide
                    }
                }
                let available = await MainActor.run { cam.availableLenses() }
                if !available.contains(lens) {
                    return "Lens '\(lens.rawValue)' not available. Available: \(available.map(\.rawValue).joined(separator: ", "))"
                }
                await MainActor.run { cam.setCamera(position: position, lens: lens) }
                let pos = await MainActor.run { cam.currentCameraPosition }
                return "Camera set to \(pos == .front ? "front" : "back") with \(lens.rawValue) lens"
            }
        )
    }

    public var setManualExposureTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "set_manual_exposure",
            description: "Set manual exposure with ISO and shutter speed. ISO range: typically 32-3200. Shutter speed in seconds (e.g. 0.001 for 1/1000s, 0.033 for 1/30s).",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "iso": .object(["type": .string("number"), "description": .string("ISO sensitivity (e.g. 100, 400, 1600)")]),
                    "shutter_speed": .object(["type": .string("number"), "description": .string("Shutter speed in seconds")]),
                ]),
            ]),
            skipPermission: true,
            handler: { args in
                var iso: Float?
                var shutterSpeed: Double?
                if case .object(let dict) = args {
                    if case .double(let i) = dict["iso"] { iso = Float(i) }
                    else if case .int(let i) = dict["iso"] { iso = Float(i) }
                    if case .double(let s) = dict["shutter_speed"] { shutterSpeed = s }
                }
                await MainActor.run { cam.setManualExposure(iso: iso, shutterSpeed: shutterSpeed) }
                var parts: [String] = []
                if let iso { parts.append("ISO \(Int(iso))") }
                if let shutterSpeed { parts.append("shutter 1/\(Int(1.0/shutterSpeed))s") }
                return "Manual exposure set: \(parts.joined(separator: ", "))"
            }
        )
    }

    public var setWhiteBalanceTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "set_white_balance",
            description: "Set white balance temperature. Values: 2700K=warm/tungsten, 4000K=fluorescent, 5500K=daylight, 6500K=cloudy, 7500K=shade. Use 'auto' to reset.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "temperature": .object([
                        "type": .string("number"),
                        "description": .string("Color temperature in Kelvin (2000-10000), or 0 for auto"),
                    ]),
                ]),
                "required": .array([.string("temperature")]),
            ]),
            skipPermission: true,
            handler: { args in
                let temp: Float
                if case .object(let dict) = args, case .double(let t) = dict["temperature"] { temp = Float(t) }
                else if case .object(let dict) = args, case .int(let t) = dict["temperature"] { temp = Float(t) }
                else { return "Error: temperature required" }
                if temp == 0 {
                    await MainActor.run { cam.setWhiteBalanceAuto() }
                    return "White balance set to auto"
                }
                await MainActor.run { cam.setWhiteBalance(temperature: temp) }
                return "White balance set to \(Int(temp))K"
            }
        )
    }

    public var pauseRecordingTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "pause_recording",
            description: "Pause the current video recording without stopping it.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                await MainActor.run { cam.pauseRecording() }
                return "Recording paused."
            }
        )
    }

    public var resumeRecordingTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "resume_recording",
            description: "Resume a paused video recording.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                await MainActor.run { cam.resumeRecording() }
                return "Recording resumed."
            }
        )
    }

    public var deviceInfoTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "get_device_info",
            description: "Get current camera device capabilities: available lenses, zoom range, ISO range, recording state.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let info = await MainActor.run { cam.deviceInfo() }
                return info.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
            }
        )
    }

    // MARK: - Vision Tools

    public var detectObjectsTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "detect_objects",
            description: "Detect objects (animals, etc.) in the current camera frame. Returns labels, confidence, and positions.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available. Try observe_camera first."
                }
                let buf = sendableBuf.buffer
                let objects = await analyzer.detectObjects(pixelBuffer: buf)
                if objects.isEmpty {
                    return "No objects detected in current frame."
                }
                return objects.map {
                    "\($0.label) (confidence: \(String(format: "%.0f%%", $0.confidence * 100)), position: (\(String(format: "%.2f", $0.boundingBox.midX)), \(String(format: "%.2f", $0.boundingBox.midY))))"
                }.joined(separator: "\n")
            }
        )
    }

    public var detectFacesTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "detect_faces",
            description: "Detect faces in the current camera frame. Returns positions, confidence, and head orientation.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available."
                }
                let buf = sendableBuf.buffer
                let faces = await analyzer.detectFaces(pixelBuffer: buf)
                if faces.isEmpty {
                    return "No faces detected."
                }
                return faces.enumerated().map { (i, face) in
                    var desc = "Face \(i+1): position (\(String(format: "%.2f", face.boundingBox.midX)), \(String(format: "%.2f", face.boundingBox.midY))), size \(String(format: "%.0f%%", face.boundingBox.width * 100)) of frame"
                    if let yaw = face.yaw {
                        let dir = yaw < -0.2 ? "looking right" : yaw > 0.2 ? "looking left" : "facing camera"
                        desc += ", \(dir)"
                    }
                    return desc
                }.joined(separator: "\n")
            }
        )
    }

    public var detectPoseTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "detect_pose",
            description: "Detect human body poses in the current frame. Returns joint positions (head, shoulders, elbows, wrists, hips, knees, ankles).",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available."
                }
                let buf = sendableBuf.buffer
                let poses = await analyzer.detectPoses(pixelBuffer: buf)
                if poses.isEmpty {
                    return "No human poses detected."
                }
                return poses.enumerated().map { (i, pose) in
                    let jointStr = pose.joints.sorted(by: { $0.key < $1.key }).map {
                        "\($0.key): (\(String(format: "%.2f", $0.value.x)), \(String(format: "%.2f", $0.value.y)))"
                    }.joined(separator: ", ")
                    return "Person \(i+1) (confidence: \(String(format: "%.0f%%", pose.confidence * 100))): \(jointStr)"
                }.joined(separator: "\n")
            }
        )
    }

    // MARK: - Director Tools

    public var analyzeShotTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "analyze_shot",
            description: "Run comprehensive shot analysis: scene classification, face detection, pose detection, and composition evaluation (rule of thirds, headroom, leading space).",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available. Try observe_camera first."
                }
                let buf = sendableBuf.buffer
                let analysis = await analyzer.analyzeShot(pixelBuffer: buf)
                var result: [String] = []
                result.append("=== Scene ===")
                result.append("Labels: \(analysis.scene.sceneLabels.joined(separator: ", "))")
                result.append("Lighting: \(analysis.scene.lighting.rawValue)")
                result.append("Aesthetic: \(String(format: "%.1f", analysis.scene.aestheticScore))/1.0")

                if !analysis.faces.isEmpty {
                    result.append("\n=== Faces (\(analysis.faces.count)) ===")
                    for (i, face) in analysis.faces.enumerated() {
                        result.append("Face \(i+1): center (\(String(format: "%.2f", face.boundingBox.midX)), \(String(format: "%.2f", face.boundingBox.midY))), size \(String(format: "%.0f%%", face.boundingBox.width * 100))")
                    }
                }

                if !analysis.poses.isEmpty {
                    result.append("\n=== Poses (\(analysis.poses.count)) ===")
                    for (i, pose) in analysis.poses.enumerated() {
                        result.append("Person \(i+1): \(pose.joints.count) joints detected")
                    }
                }

                result.append("\n=== Composition ===")
                result.append("Score: \(String(format: "%.1f", analysis.composition.overallScore))/1.0")
                result.append("Rule of thirds: \(String(format: "%.0f%%", analysis.composition.ruleOfThirdsScore * 100))")
                result.append("Headroom: \(analysis.composition.headroomOk ? "✓" : "✗")")
                result.append("Leading space: \(analysis.composition.leadingSpaceOk ? "✓" : "✗")")
                result.append("Feedback: \(analysis.composition.feedback)")

                return result.joined(separator: "\n")
            }
        )
    }

    // MARK: - New Vision Tools

    public var detectHorizonTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "detect_horizon",
            description: "Detect whether the camera is level. Returns tilt angle and whether it's within acceptable range.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available."
                }
                let buf = sendableBuf.buffer
                let info = await analyzer.detectHorizon(pixelBuffer: buf)
                return "Angle: \(String(format: "%.1f", info.angle))°, Level: \(info.isLevel ? "yes" : "no"). \(info.feedback)"
            }
        )
    }

    public var detectBlurTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "detect_blur",
            description: "Check if the current camera frame is sharp or blurry. Returns sharpness score (0-1) and feedback.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available."
                }
                let buf = sendableBuf.buffer
                let info = await analyzer.detectBlur(pixelBuffer: buf)
                return "Sharpness: \(String(format: "%.2f", info.sharpness))/1.0, Sharp: \(info.isSharp ? "yes" : "no"). \(info.feedback)"
            }
        )
    }

    public var classifyShotTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "classify_shot",
            description: "Classify the current shot type based on face size: extreme close-up, close-up, medium close-up, medium, medium wide, wide, or establishing.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available."
                }
                let buf = sendableBuf.buffer
                let faces = await analyzer.detectFaces(pixelBuffer: buf)
                let shotType = await MainActor.run { analyzer.classifyShotType(faces: faces) }
                return "Shot type: \(shotType.rawValue)"
            }
        )
    }

    public var classifySceneTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "classify_scene",
            description: "Classify the scene type: talking head, interview, vlog, product demo, landscape, action, group, or unknown.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available."
                }
                let scene = await analyzer.analyze(pixelBuffer: sendableBuf.buffer)
                let faces = await analyzer.detectFaces(pixelBuffer: sendableBuf.buffer)
                let poses = await analyzer.detectPoses(pixelBuffer: sendableBuf.buffer)
                guard let scene else { return "No scene analysis available." }
                let sceneType = await MainActor.run { analyzer.classifySceneType(scene: scene, faces: faces, poses: poses) }
                return "Scene type: \(sceneType.rawValue)"
            }
        )
    }

    public var detectRectanglesTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "detect_rectangles",
            description: "Detect rectangular shapes in the frame (screens, documents, whiteboards, signs).",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available."
                }
                let buf = sendableBuf.buffer
                let rects = await analyzer.detectRectangles(pixelBuffer: buf)
                if rects.isEmpty { return "No rectangles detected." }
                return rects.enumerated().map { (i, r) in
                    "Rectangle \(i+1): center (\(String(format: "%.2f", r.boundingBox.midX)), \(String(format: "%.2f", r.boundingBox.midY))), size \(String(format: "%.0f%%", r.boundingBox.width * 100))x\(String(format: "%.0f%%", r.boundingBox.height * 100)) of frame, confidence \(String(format: "%.0f%%", r.confidence * 100))"
                }.joined(separator: "\n")
            }
        )
    }

    public var trackSubjectTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "track_subject",
            description: "Track a subject in the frame given an initial bounding box. Provide normalized coordinates (0-1). Returns updated position.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("Left edge of bounding box (0-1)")]),
                    "y": .object(["type": .string("number"), "description": .string("Top edge of bounding box (0-1)")]),
                    "width": .object(["type": .string("number"), "description": .string("Width of bounding box (0-1)")]),
                    "height": .object(["type": .string("number"), "description": .string("Height of bounding box (0-1)")]),
                ]),
                "required": .array([.string("x"), .string("y"), .string("width"), .string("height")]),
            ]),
            skipPermission: true,
            handler: { args in
                guard case .object(let dict) = args else { return "Error: bounding box required" }
                let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
                if case .double(let v) = dict["x"] { x = CGFloat(v) } else if case .int(let v) = dict["x"] { x = CGFloat(v) } else { return "Error: x required" }
                if case .double(let v) = dict["y"] { y = CGFloat(v) } else if case .int(let v) = dict["y"] { y = CGFloat(v) } else { return "Error: y required" }
                if case .double(let v) = dict["width"] { w = CGFloat(v) } else if case .int(let v) = dict["width"] { w = CGFloat(v) } else { return "Error: width required" }
                if case .double(let v) = dict["height"] { h = CGFloat(v) } else if case .int(let v) = dict["height"] { h = CGFloat(v) } else { return "Error: height required" }

                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available."
                }
                let buf = sendableBuf.buffer
                let bbox = CGRect(x: x, y: y, width: w, height: h)
                if let tracked = await analyzer.trackSubject(initialBBox: bbox, in: buf) {
                    return "Tracked position: x=\(String(format: "%.2f", tracked.minX)), y=\(String(format: "%.2f", tracked.minY)), width=\(String(format: "%.2f", tracked.width)), height=\(String(format: "%.2f", tracked.height))"
                }
                return "Subject tracking lost — could not find subject at given location."
            }
        )
    }

    // MARK: - Slow Motion & Audio Tools

    public var setSlowMotionTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "set_slow_motion",
            description: "Set slow motion recording mode. 'normal'=30fps, 'slo120'=120fps (4x slow), 'slo240'=240fps (8x slow). Set BEFORE starting recording.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("normal"), .string("slo120"), .string("slo240")]),
                        "description": .string("Slow motion mode"),
                    ]),
                ]),
                "required": .array([.string("mode")]),
            ]),
            skipPermission: true,
            handler: { args in
                let modeStr: String
                if case .object(let dict) = args, case .string(let m) = dict["mode"] {
                    modeStr = m
                } else {
                    return "Error: mode required (normal/slo120/slo240)"
                }
                guard let mode = CameraService.SlowMotionMode(rawValue: modeStr) else {
                    return "Error: invalid mode. Use: normal, slo120, slo240"
                }
                await MainActor.run { cam.setSlowMotion(mode) }
                let fpsLabel = mode == .normal ? "30fps" : mode == .slo120 ? "120fps" : "240fps"
                return "Slow motion set to \(modeStr) (\(fpsLabel))"
            }
        )
    }

    public var getAudioLevelsTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "get_audio_levels",
            description: "Get current audio level and description. Starts monitoring if not already active. Returns level (0-1) and description (silent/quiet/moderate/loud/very loud).",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            skipPermission: true,
            handler: { _ in
                let isMonitoring = await MainActor.run { cam.audioEngine != nil }
                if !isMonitoring {
                    await MainActor.run { cam.startAudioMonitoring() }
                    try? await Task.sleep(for: .milliseconds(500)) // Let it settle
                }
                let level = await MainActor.run { cam.audioLevel }
                let desc = await MainActor.run { cam.audioLevelDescription() }
                return "Audio level: \(String(format: "%.2f", level)) (\(desc))"
            }
        )
    }

    // MARK: - Image Generation

    public var generateImageTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "generate_image",
            description: "Generate a stylized image from a text description using Apple Image Playground. Styles: 'animation' (cartoon), 'illustration', 'sketch'. Can also use the current camera frame as source. Returns the saved file path.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("Text description of the image to generate"),
                    ]),
                    "style": .object([
                        "type": .string("string"),
                        "enum": .array([.string("animation"), .string("illustration"), .string("sketch")]),
                        "description": .string("Image style (default: animation)"),
                    ]),
                    "use_camera_frame": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, uses current camera frame as source image for style transfer"),
                    ]),
                ]),
                "required": .array([.string("description")]),
            ]),
            skipPermission: true,
            handler: { args in
                #if canImport(ImagePlayground)
                guard case .object(let dict) = args else { return "Error: description required" }
                guard case .string(let desc) = dict["description"] else { return "Error: description required" }

                let styleStr: String
                if case .string(let s) = dict["style"] { styleStr = s } else { styleStr = "animation" }

                let useCameraFrame: Bool
                if case .bool(let b) = dict["use_camera_frame"] { useCameraFrame = b } else { useCameraFrame = false }

                if #available(iOS 18.4, *) {
                    return await Self.generateImage(
                    description: desc,
                    style: styleStr,
                    useCameraFrame: useCameraFrame,
                        camera: cam
                    )
                } else {
                    return "Image generation requires iOS 18.4 or later."
                }
                #else
                return "Image generation not available on this platform."
                #endif
            }
        )
    }

    #if canImport(ImagePlayground)

    @available(iOS 18.4, *)
    private static func generateImage(
        description: String,
        style: String,
        useCameraFrame: Bool,
        camera: CameraService
    ) async -> String {
        do {
            let creator = try await ImageCreator()

            var concepts: [ImagePlaygroundConcept] = [.text(description)]

            if useCameraFrame {
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
            switch style {
            case "illustration": playgroundStyle = .illustration
            case "sketch": playgroundStyle = .sketch
            default: playgroundStyle = .animation
            }

            for try await result in creator.images(for: concepts, style: playgroundStyle, limit: 1) {
                // Save to documents
                let filename = "generated_\(Int(Date().timeIntervalSince1970)).png"
                let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileURL = docsDir.appendingPathComponent(filename)
                if let data = UIImage(cgImage: result.cgImage).pngData() {
                    try data.write(to: fileURL)
                    return "Image generated and saved: \(filename) (style: \(style))"
                }
            }
            return "Image generation completed but no result received."
        } catch {
            return "Image generation failed: \(error.localizedDescription)"
        }
    }
    #endif

    // MARK: - Camera Animation Tool

    /// Animate camera parameters over time using keyframes with easing curves.
    public var animateCameraTool: ToolDefinition {
        let animator = self.animator
        let cam = self.camera
        return ToolDefinition(
            name: "animate_camera",
            description: """
            Animate camera parameters over time using keyframes. Each keyframe defines a point in time \
            with target parameter values and an easing curve for the transition TO the next keyframe. \
            Supports: zoom, exposure, focus_x, focus_y, white_balance, iso, shutter_speed. \
            Easing: "linear", "ease_in", "ease_out", "ease_in_out", "spring". \
            Optionally auto-starts recording for the animation duration. \
            Blocks until the animation completes.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "keyframes": .object([
                        "type": .string("array"),
                        "description": .string("Array of keyframe objects. Each has 'time' (seconds) and optional parameter values."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "time": .object(["type": .string("number"), "description": .string("Time in seconds from animation start")]),
                                "easing": .object(["type": .string("string"), "description": .string("Easing curve: linear, ease_in, ease_out, ease_in_out, spring")]),
                                "zoom": .object(["type": .string("number"), "description": .string("Zoom level (1.0 = normal)")]),
                                "exposure": .object(["type": .string("number"), "description": .string("Exposure compensation EV (-2 to +2)")]),
                                "focus_x": .object(["type": .string("number"), "description": .string("Focus point X (0-1)")]),
                                "focus_y": .object(["type": .string("number"), "description": .string("Focus point Y (0-1)")]),
                                "white_balance": .object(["type": .string("number"), "description": .string("Color temperature in Kelvin")]),
                                "iso": .object(["type": .string("number"), "description": .string("ISO sensitivity")]),
                                "shutter_speed": .object(["type": .string("number"), "description": .string("Shutter speed in seconds")]),
                            ]),
                            "required": .array([.string("time")]),
                        ]),
                    ]),
                    "duration": .object([
                        "type": .string("number"),
                        "description": .string("Total animation duration in seconds (default: last keyframe time)"),
                    ]),
                    "record": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, automatically record video during the animation (default: false)"),
                    ]),
                ]),
                "required": .array([.string("keyframes")]),
            ]),
            skipPermission: true,
            handler: { args in
                guard case .object(let dict) = args,
                      case .array(let kfArray) = dict["keyframes"] else {
                    return "Error: 'keyframes' array required"
                }

                // Parse keyframes
                var keyframes: [CameraKeyframe] = []
                for item in kfArray {
                    guard case .object(let kf) = item else { continue }

                    let time: Double = {
                        if case .double(let t) = kf["time"] { return t }
                        if case .int(let t) = kf["time"] { return Double(t) }
                        return 0
                    }()

                    let easingStr: String = {
                        if case .string(let e) = kf["easing"] { return e }
                        return "linear"
                    }()
                    let easing = AnimationEasing.from(string: easingStr)

                    let zoom: Double? = {
                        if case .double(let v) = kf["zoom"] { return v }
                        if case .int(let v) = kf["zoom"] { return Double(v) }
                        return nil
                    }()
                    let exposure: Double? = {
                        if case .double(let v) = kf["exposure"] { return v }
                        if case .int(let v) = kf["exposure"] { return Double(v) }
                        return nil
                    }()
                    let focusX: Double? = {
                        if case .double(let v) = kf["focus_x"] { return v }
                        if case .int(let v) = kf["focus_x"] { return Double(v) }
                        return nil
                    }()
                    let focusY: Double? = {
                        if case .double(let v) = kf["focus_y"] { return v }
                        if case .int(let v) = kf["focus_y"] { return Double(v) }
                        return nil
                    }()
                    let wb: Double? = {
                        if case .double(let v) = kf["white_balance"] { return v }
                        if case .int(let v) = kf["white_balance"] { return Double(v) }
                        return nil
                    }()
                    let iso: Double? = {
                        if case .double(let v) = kf["iso"] { return v }
                        if case .int(let v) = kf["iso"] { return Double(v) }
                        return nil
                    }()
                    let shutter: Double? = {
                        if case .double(let v) = kf["shutter_speed"] { return v }
                        return nil
                    }()

                    keyframes.append(CameraKeyframe(
                        time: time,
                        easing: easing,
                        zoom: zoom,
                        exposure: exposure,
                        focusX: focusX,
                        focusY: focusY,
                        whiteBalance: wb,
                        iso: iso,
                        shutterSpeed: shutter
                    ))
                }

                guard !keyframes.isEmpty else {
                    return "Error: No valid keyframes provided"
                }

                // Parse duration
                let duration: Double? = {
                    if case .double(let d) = dict["duration"] { return d }
                    if case .int(let d) = dict["duration"] { return Double(d) }
                    return nil
                }()

                // Parse record flag
                let shouldRecord: Bool = {
                    if case .bool(let r) = dict["record"] { return r }
                    return false
                }()

                // Start recording if requested
                if shouldRecord {
                    await MainActor.run { cam.startRecording() }
                    // Small delay to let recording stabilize
                    try? await Task.sleep(for: .milliseconds(200))
                }

                // Run animation (blocks until complete)
                let animDuration = duration ?? (keyframes.last?.time ?? 0)

                // Bridge to MainActor for the animation (CADisplayLink must run on main)
                let kfs = keyframes
                let dur = duration
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    Task { @MainActor in
                        await animator.animate(keyframes: kfs, duration: dur)
                        cont.resume()
                    }
                }

                // Stop recording if we started it
                if shouldRecord {
                    let url = await cam.stopRecording()
                    let fileName = url?.lastPathComponent ?? "unknown"
                    return "Animation complete (\(String(format: "%.1f", animDuration))s, \(kfs.count) keyframes). Recording saved: \(fileName)"
                }

                return "Animation complete (\(String(format: "%.1f", animDuration))s, \(kfs.count) keyframes)"
            }
        )
    }

    // MARK: - Unified Tools (Compact Mode)

    /// Unified camera configuration — set multiple camera parameters in one call.
    public var configureCameraTool: ToolDefinition {
        let cam = camera
        return ToolDefinition(
            name: "configure_camera",
            description: """
            Configure multiple camera settings in one call. All parameters are optional — only provided values are changed.
            Position: "front"/"back". Lens: "wide"/"ultraWide"/"telephoto".
            Zoom: 1.0=normal. Exposure: -2.0 to +2.0 EV. ISO: 32-3200. Shutter: seconds (0.001=1/1000s).
            Focus: x,y normalized 0-1. White balance: Kelvin (2700=warm, 5500=daylight, 0=auto).
            Flash: "off"/"on"/"auto"/"torch". Slow motion: "normal"/"slo120"/"slo240".
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "position": .object(["type": .string("string"), "enum": .array([.string("front"), .string("back")])]),
                    "lens": .object(["type": .string("string"), "enum": .array([.string("wide"), .string("ultraWide"), .string("telephoto")])]),
                    "zoom": .object(["type": .string("number"), "description": .string("Zoom level (1.0 = normal)")]),
                    "exposure": .object(["type": .string("number"), "description": .string("Exposure compensation EV (-2 to +2)")]),
                    "iso": .object(["type": .string("number"), "description": .string("ISO sensitivity")]),
                    "shutter_speed": .object(["type": .string("number"), "description": .string("Shutter speed in seconds")]),
                    "focus_x": .object(["type": .string("number"), "description": .string("Focus point X (0-1)")]),
                    "focus_y": .object(["type": .string("number"), "description": .string("Focus point Y (0-1)")]),
                    "white_balance": .object(["type": .string("number"), "description": .string("Temperature in Kelvin, 0=auto")]),
                    "flash": .object(["type": .string("string"), "enum": .array([.string("off"), .string("on"), .string("auto"), .string("torch")])]),
                    "slow_motion": .object(["type": .string("string"), "enum": .array([.string("normal"), .string("slo120"), .string("slo240")])]),
                ]),
            ]),
            skipPermission: true,
            handler: { args in
                guard case .object(let dict) = args else { return "Error: provide settings as object" }
                var applied: [String] = []

                // Position + lens
                if dict["position"] != nil || dict["lens"] != nil {
                    var position: AVCaptureDevice.Position?
                    var lens: CameraService.LensType = .wide
                    if case .string(let p) = dict["position"] { position = p == "front" ? .front : .back }
                    if case .string(let l) = dict["lens"] { lens = CameraService.LensType(rawValue: l) ?? .wide }
                    await MainActor.run { cam.setCamera(position: position, lens: lens) }
                    let pos = await MainActor.run { cam.currentCameraPosition }
                    applied.append("\(pos == .front ? "front" : "back") camera, \(lens.rawValue) lens")
                }

                // Zoom
                if case .double(let z) = dict["zoom"] {
                    await MainActor.run { cam.setZoom(CGFloat(z)) }
                    applied.append("zoom \(String(format: "%.1f", z))x")
                } else if case .int(let z) = dict["zoom"] {
                    await MainActor.run { cam.setZoom(CGFloat(z)) }
                    applied.append("zoom \(z)x")
                }

                // Exposure compensation
                if case .double(let e) = dict["exposure"] {
                    await MainActor.run { cam.setExposure(Float(e)) }
                    applied.append("exposure \(String(format: "%+.1f", e)) EV")
                } else if case .int(let e) = dict["exposure"] {
                    await MainActor.run { cam.setExposure(Float(e)) }
                    applied.append("exposure \(e > 0 ? "+" : "")\(e) EV")
                }

                // Manual exposure (ISO + shutter)
                let iso: Float? = {
                    if case .double(let i) = dict["iso"] { return Float(i) }
                    if case .int(let i) = dict["iso"] { return Float(i) }
                    return nil
                }()
                let shutter: Double? = {
                    if case .double(let s) = dict["shutter_speed"] { return s }
                    return nil
                }()
                if iso != nil || shutter != nil {
                    await MainActor.run { cam.setManualExposure(iso: iso, shutterSpeed: shutter) }
                    if let iso { applied.append("ISO \(Int(iso))") }
                    if let shutter { applied.append("shutter 1/\(Int(1.0/shutter))s") }
                }

                // Focus
                let focusX: Float? = {
                    if case .double(let x) = dict["focus_x"] { return Float(x) }
                    if case .int(let x) = dict["focus_x"] { return Float(x) }
                    return nil
                }()
                let focusY: Float? = {
                    if case .double(let y) = dict["focus_y"] { return Float(y) }
                    if case .int(let y) = dict["focus_y"] { return Float(y) }
                    return nil
                }()
                if let x = focusX, let y = focusY {
                    await MainActor.run { cam.setFocus(x: x, y: y) }
                    applied.append("focus (\(String(format: "%.2f", x)), \(String(format: "%.2f", y)))")
                }

                // White balance
                if case .double(let t) = dict["white_balance"] {
                    if t == 0 {
                        await MainActor.run { cam.setWhiteBalanceAuto() }
                        applied.append("white balance auto")
                    } else {
                        await MainActor.run { cam.setWhiteBalance(temperature: Float(t)) }
                        applied.append("white balance \(Int(t))K")
                    }
                } else if case .int(let t) = dict["white_balance"] {
                    if t == 0 {
                        await MainActor.run { cam.setWhiteBalanceAuto() }
                        applied.append("white balance auto")
                    } else {
                        await MainActor.run { cam.setWhiteBalance(temperature: Float(t)) }
                        applied.append("white balance \(t)K")
                    }
                }

                // Flash
                if case .string(let f) = dict["flash"], let mode = CameraService.FlashMode(rawValue: f) {
                    await MainActor.run { cam.setFlash(mode) }
                    applied.append("flash \(f)")
                }

                // Slow motion
                if case .string(let s) = dict["slow_motion"], let mode = CameraService.SlowMotionMode(rawValue: s) {
                    await MainActor.run { cam.setSlowMotion(mode) }
                    let fpsLabel = mode == .normal ? "30fps" : mode == .slo120 ? "120fps" : "240fps"
                    applied.append("slow motion \(s) (\(fpsLabel))")
                }

                return applied.isEmpty
                    ? "No settings provided. Pass any of: position, lens, zoom, exposure, iso, shutter_speed, focus_x, focus_y, white_balance, flash."
                    : "Camera configured: \(applied.joined(separator: ", "))"
            }
        )
    }

    /// Unified vision analysis — runs all detection in parallel with one call.
    public var analyzeVisionTool: ToolDefinition {
        let cam = camera
        let analyzer = self.analyzer
        return ToolDefinition(
            name: "analyze_vision",
            description: """
            Run comprehensive vision analysis on the current camera frame in one call.
            Returns: scene classification, detected text, objects, faces (with orientation), 
            body poses (with joints), lighting conditions, composition quality score,
            horizon level, image sharpness, shot type, scene type, and detected rectangles.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "include": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("What to analyze: 'scene', 'objects', 'faces', 'poses', 'composition', 'horizon', 'blur', 'shot_type', 'scene_type', 'rectangles', 'all' (default: 'all')"),
                    ]),
                ]),
            ]),
            skipPermission: true,
            handler: { _ in
                let sendableBuf: SendablePixelBuffer? = await MainActor.run {
                    if let buf = cam.latestPixelBuffer { return SendablePixelBuffer(buffer: buf) }
                    return nil
                }
                guard let sendableBuf else {
                    return "No camera frame available. Try observe_camera first."
                }

                // Run analysis sequentially (CVPixelBuffer can't be sent across concurrent tasks)
                let scene = await analyzer.analyze(pixelBuffer: sendableBuf.buffer)
                let objects = await analyzer.detectObjects(pixelBuffer: sendableBuf.buffer)
                let faces = await analyzer.detectFaces(pixelBuffer: sendableBuf.buffer)
                let poses = await analyzer.detectPoses(pixelBuffer: sendableBuf.buffer)
                let horizon = await analyzer.detectHorizon(pixelBuffer: sendableBuf.buffer)
                let blur = await analyzer.detectBlur(pixelBuffer: sendableBuf.buffer)
                let rects = await analyzer.detectRectangles(pixelBuffer: sendableBuf.buffer)

                var result: [String] = []

                // Scene
                if let scene {
                    result.append("=== Scene ===")
                    result.append("Labels: \(scene.sceneLabels.joined(separator: ", "))")
                    result.append("Lighting: \(scene.lighting.rawValue)")
                    if !scene.recognizedTexts.isEmpty {
                        result.append("Text: \(scene.recognizedTexts.joined(separator: ", "))")
                    }
                    result.append("Aesthetic: \(String(format: "%.1f", scene.aestheticScore))/1.0")
                }

                // Shot & Scene Type
                let shotType = await MainActor.run { analyzer.classifyShotType(faces: faces) }
                result.append("\n=== Classification ===")
                result.append("Shot type: \(shotType.rawValue)")
                if let scene {
                    let sceneType = await MainActor.run { analyzer.classifySceneType(scene: scene, faces: faces, poses: poses) }
                    result.append("Scene type: \(sceneType.rawValue)")
                }

                // Objects
                if !objects.isEmpty {
                    result.append("\n=== Objects (\(objects.count)) ===")
                    for obj in objects {
                        result.append("\(obj.label) (\(String(format: "%.0f%%", obj.confidence * 100))) at (\(String(format: "%.2f", obj.boundingBox.midX)), \(String(format: "%.2f", obj.boundingBox.midY)))")
                    }
                }

                // Faces
                if !faces.isEmpty {
                    result.append("\n=== Faces (\(faces.count)) ===")
                    for (i, face) in faces.enumerated() {
                        var desc = "Face \(i+1): center (\(String(format: "%.2f", face.boundingBox.midX)), \(String(format: "%.2f", face.boundingBox.midY))), size \(String(format: "%.0f%%", face.boundingBox.width * 100))"
                        if let yaw = face.yaw {
                            let dir = yaw < -0.2 ? "looking right" : yaw > 0.2 ? "looking left" : "facing camera"
                            desc += ", \(dir)"
                        }
                        result.append(desc)
                    }
                }

                // Poses
                if !poses.isEmpty {
                    result.append("\n=== Poses (\(poses.count)) ===")
                    for (i, pose) in poses.enumerated() {
                        let mainJoints = ["nose", "neck", "right_shoulder", "left_shoulder", "right_wrist", "left_wrist"]
                            .compactMap { key -> String? in
                                guard let point = pose.joints[key] else { return nil }
                                return "\(key): (\(String(format: "%.2f", point.x)), \(String(format: "%.2f", point.y)))"
                            }
                        result.append("Person \(i+1) (\(String(format: "%.0f%%", pose.confidence * 100))): \(mainJoints.joined(separator: ", "))")
                    }
                }

                // Horizon & Blur
                result.append("\n=== Quality ===")
                result.append("Horizon: \(String(format: "%.1f", horizon.angle))° — \(horizon.feedback)")
                result.append("Sharpness: \(String(format: "%.2f", blur.sharpness))/1.0 — \(blur.feedback)")

                // Rectangles
                if !rects.isEmpty {
                    result.append("\n=== Rectangles (\(rects.count)) ===")
                    for (i, r) in rects.enumerated() {
                        result.append("Rect \(i+1): center (\(String(format: "%.2f", r.boundingBox.midX)), \(String(format: "%.2f", r.boundingBox.midY))), size \(String(format: "%.0f%%", r.boundingBox.width * 100))x\(String(format: "%.0f%%", r.boundingBox.height * 100))")
                    }
                }

                // Composition (if faces detected)
                if let scene, !faces.isEmpty {
                    let composition = await MainActor.run { analyzer.evaluateComposition(scene: scene, faces: faces, poses: poses) }
                    result.append("\n=== Composition ===")
                    result.append("Score: \(String(format: "%.1f", composition.overallScore))/1.0")
                    result.append("Feedback: \(composition.feedback)")
                }

                return result.isEmpty ? "No analysis results." : result.joined(separator: "\n")
            }
        )
    }
}
#endif
