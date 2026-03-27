#if os(iOS)
import Foundation
import Vision
import CoreImage
import UIKit

/// Vision framework scene analyzer — classifies scenes, detects text, estimates lighting.
@MainActor
public final class SceneAnalyzer: ObservableObject {

    /// Analysis result from a single frame.
    public struct SceneContext: Sendable {
        public let sceneLabels: [String]
        public let recognizedTexts: [String]
        public let aestheticScore: Float
        public let lighting: Lighting
        public let focalPoints: [CGPoint]
        public let timestamp: Date

        public init(sceneLabels: [String], recognizedTexts: [String], aestheticScore: Float,
                    lighting: Lighting, focalPoints: [CGPoint], timestamp: Date) {
            self.sceneLabels = sceneLabels
            self.recognizedTexts = recognizedTexts
            self.aestheticScore = aestheticScore
            self.lighting = lighting
            self.focalPoints = focalPoints
            self.timestamp = timestamp
        }

        /// Human-readable description.
        public var description: String {
            var parts: [String] = []
            let labels = sceneLabels.prefix(3).map { $0.replacingOccurrences(of: "_", with: " ") }
            parts.append(contentsOf: labels)
            parts.append(lighting.rawValue.lowercased())
            return parts.isEmpty ? "Unknown scene" : parts.joined(separator: " · ")
        }
    }

    public enum Lighting: String, Sendable {
        case bright = "Bright"
        case warm = "Warm"
        case dim = "Dim"
        case dark = "Dark"
        case backlit = "Backlit"
    }

    @Published public var latestContext: SceneContext?
    @Published public var isAnalyzing = false

    public init() {}

    /// Analyze a pixel buffer from camera output.
    public func analyze(pixelBuffer: sending CVPixelBuffer) async -> SceneContext? {
        guard !isAnalyzing else { return nil }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let sendable = SendablePixelBuffer(buffer: pixelBuffer)

        return await Task.detached { [weak self] () -> SceneContext? in
            let handler = VNImageRequestHandler(cvPixelBuffer: sendable.buffer, options: [:])

            let classifyRequest = VNClassifyImageRequest()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .fast
            let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()

            try? handler.perform([classifyRequest, textRequest, saliencyRequest])

            let sceneLabels = (classifyRequest.results ?? [])
                .filter { $0.confidence > 0.1 }
                .prefix(5)
                .map { $0.identifier }

            let texts = (textRequest.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }

            var focalPoints: [CGPoint] = []
            if let saliencyMap = saliencyRequest.results?.first {
                focalPoints = (saliencyMap.salientObjects ?? []).map {
                    CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)
                }
            }

            let lighting = Self.estimateLighting(pixelBuffer: sendable.buffer)
            let aestheticScore = min(1.0, Float(sceneLabels.count) * 0.15 + Float(focalPoints.count) * 0.2 + 0.3)

            let context = SceneContext(
                sceneLabels: Array(sceneLabels),
                recognizedTexts: texts,
                aestheticScore: aestheticScore,
                lighting: lighting,
                focalPoints: focalPoints,
                timestamp: Date()
            )

            await MainActor.run { [weak self] in
                self?.latestContext = context
            }

            return context
        }.value
    }

    /// Analyze a UIImage.
    public func analyze(image: UIImage) async -> SceneContext? {
        guard let cgImage = image.cgImage else { return nil }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let classifyRequest = VNClassifyImageRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()

        try? handler.perform([classifyRequest, textRequest, saliencyRequest])

        let sceneLabels = (classifyRequest.results ?? [])
            .filter { $0.confidence > 0.1 }
            .prefix(5)
            .map { $0.identifier }

        let texts = (textRequest.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }

        var focalPoints: [CGPoint] = []
        if let saliencyMap = saliencyRequest.results?.first {
            focalPoints = (saliencyMap.salientObjects ?? []).map {
                CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)
            }
        }

        let aestheticScore = min(1.0, Float(sceneLabels.count) * 0.15 + Float(focalPoints.count) * 0.2 + 0.3)

        let context = SceneContext(
            sceneLabels: Array(sceneLabels),
            recognizedTexts: texts,
            aestheticScore: aestheticScore,
            lighting: .bright,
            focalPoints: focalPoints,
            timestamp: Date()
        )

        latestContext = context
        return context
    }

    // MARK: - Lighting Estimation

    private nonisolated static func estimateLighting(pixelBuffer: CVPixelBuffer) -> Lighting {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return .bright }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var totalBrightness: Double = 0
        let sampleCount = 20
        let stepX = width / sampleCount
        let stepY = height / sampleCount
        var samples = 0

        for sy in stride(from: 0, to: height, by: stepY) {
            for sx in stride(from: 0, to: width, by: stepX) {
                let offset = sy * bytesPerRow + sx * 4
                if offset + 2 < bytesPerRow * height {
                    let r = Double(buffer[offset])
                    let g = Double(buffer[offset + 1])
                    let b = Double(buffer[offset + 2])
                    totalBrightness += (r + g + b) / 3.0
                    samples += 1
                }
            }
        }

        guard samples > 0 else { return .bright }
        let avgBrightness = totalBrightness / Double(samples)

        switch avgBrightness {
        case 0..<40: return .dark
        case 40..<80: return .dim
        case 80..<160: return .warm
        default: return .bright
        }
    }

    // MARK: - Object Detection

    /// Detected object in frame.
    public struct DetectedObject: Sendable {
        public let label: String
        public let confidence: Float
        public let boundingBox: CGRect  // normalized 0-1
    }

    /// Detect objects in the current frame. Returns labeled objects with positions.
    public func detectObjects(pixelBuffer: sending CVPixelBuffer) async -> [DetectedObject] {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)
        return await Task.detached {
            let handler = VNImageRequestHandler(cvPixelBuffer: sendable.buffer, options: [:])
            let request = VNRecognizeAnimalsRequest()
            try? handler.perform([request])

            var objects: [DetectedObject] = []
            for observation in request.results ?? [] {
                for label in observation.labels {
                    objects.append(DetectedObject(
                        label: label.identifier,
                        confidence: label.confidence,
                        boundingBox: observation.boundingBox
                    ))
                }
            }
            return objects
        }.value
    }

    // MARK: - Face Detection

    /// Detected face in frame.
    public struct DetectedFace: Sendable {
        public let boundingBox: CGRect  // normalized 0-1
        public let confidence: Float
        public let roll: CGFloat?       // head rotation (radians)
        public let yaw: CGFloat?        // left-right head turn
    }

    /// Detect faces in the current frame.
    public func detectFaces(pixelBuffer: sending CVPixelBuffer) async -> [DetectedFace] {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)
        return await Task.detached {
            let handler = VNImageRequestHandler(cvPixelBuffer: sendable.buffer, options: [:])
            let request = VNDetectFaceRectanglesRequest()
            try? handler.perform([request])

            return (request.results ?? []).map { face -> DetectedFace in
                let rollValue: CGFloat? = face.roll.flatMap { CGFloat($0.doubleValue) }
                let yawValue: CGFloat? = face.yaw.flatMap { CGFloat($0.doubleValue) }
                return DetectedFace(
                    boundingBox: face.boundingBox,
                    confidence: face.confidence,
                    roll: rollValue,
                    yaw: yawValue
                )
            }
        }.value
    }

    // MARK: - Pose Detection

    /// Detected human body pose.
    public struct DetectedPose: Sendable {
        /// Key body point positions (normalized 0-1). Key = joint name.
        public let joints: [String: CGPoint]
        public let confidence: Float
    }

    /// Detect human body poses in the current frame.
    public func detectPoses(pixelBuffer: sending CVPixelBuffer) async -> [DetectedPose] {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)
        return await Task.detached {
            let handler = VNImageRequestHandler(cvPixelBuffer: sendable.buffer, options: [:])
            let request = VNDetectHumanBodyPoseRequest()
            try? handler.perform([request])

            return (request.results ?? []).compactMap { observation in
                guard let points = try? observation.recognizedPoints(.all) else { return nil }

                var joints: [String: CGPoint] = [:]
                var totalConfidence: Float = 0
                var count: Float = 0

                for (key, point) in points where point.confidence > 0.1 {
                    joints[key.rawValue.rawValue] = point.location
                    totalConfidence += point.confidence
                    count += 1
                }

                guard count > 0 else { return nil }
                return DetectedPose(
                    joints: joints,
                    confidence: totalConfidence / count
                )
            }
        }.value
    }

    // MARK: - Shot Analysis

    /// Comprehensive shot analysis result.
    public struct ShotAnalysis: Sendable {
        public let scene: SceneContext
        public let faces: [DetectedFace]
        public let poses: [DetectedPose]
        public let composition: CompositionInfo
    }

    /// Composition quality assessment.
    public struct CompositionInfo: Sendable {
        /// Whether the main subject is near a rule-of-thirds intersection.
        public let ruleOfThirdsScore: Float
        /// Whether the subject has adequate headroom.
        public let headroomOk: Bool
        /// Whether the subject has leading space.
        public let leadingSpaceOk: Bool
        /// Overall composition score (0-1).
        public let overallScore: Float
        /// Human-readable feedback.
        public let feedback: String
    }

    /// Run full shot analysis: scene + faces + poses + composition.
    public func analyzeShot(pixelBuffer: sending CVPixelBuffer) async -> ShotAnalysis {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)
        // Run sequentially to avoid sending CVPixelBuffer across concurrent tasks
        let scene = await analyze(pixelBuffer: sendable.buffer) ?? SceneContext(
            sceneLabels: [], recognizedTexts: [], aestheticScore: 0,
            lighting: .bright, focalPoints: [], timestamp: Date()
        )
        let faces = await detectFaces(pixelBuffer: sendable.buffer)
        let poses = await detectPoses(pixelBuffer: sendable.buffer)

        let composition = evaluateComposition(scene: scene, faces: faces, poses: poses)

        return ShotAnalysis(scene: scene, faces: faces, poses: poses, composition: composition)
    }

    /// Evaluate composition quality from analysis results.
    /// Evaluate composition quality from analysis results.
    public func evaluateComposition(scene: SceneContext, faces: [DetectedFace], poses: [DetectedPose]) -> CompositionInfo {
        var score: Float = 0.5  // base score
        var feedback: [String] = []

        // Rule of thirds: check if main subject is near intersections
        let thirdPoints: [CGPoint] = [
            CGPoint(x: 0.333, y: 0.333), CGPoint(x: 0.667, y: 0.333),
            CGPoint(x: 0.333, y: 0.667), CGPoint(x: 0.667, y: 0.667),
        ]

        var ruleOfThirdsScore: Float = 0
        let primarySubjectCenter: CGPoint?

        if let face = faces.first {
            primarySubjectCenter = CGPoint(
                x: face.boundingBox.midX,
                y: face.boundingBox.midY
            )
        } else if let focal = scene.focalPoints.first {
            primarySubjectCenter = focal
        } else {
            primarySubjectCenter = nil
        }

        if let center = primarySubjectCenter {
            let minDist = thirdPoints.map { hypot(center.x - $0.x, center.y - $0.y) }.min() ?? 1
            ruleOfThirdsScore = max(0, 1 - Float(minDist) * 3)  // closer = higher
            score += ruleOfThirdsScore * 0.2
            if ruleOfThirdsScore > 0.5 {
                feedback.append("Good rule of thirds placement")
            } else {
                feedback.append("Try moving subject to a thirds intersection")
            }
        }

        // Headroom check (for faces)
        var headroomOk = true
        if let face = faces.first {
            let topSpace = 1.0 - face.boundingBox.maxY  // space above face (Vision coords)
            if topSpace < 0.05 {
                headroomOk = false
                feedback.append("Too little headroom — tilt down slightly")
            } else if topSpace > 0.4 {
                feedback.append("Excess headroom — tilt up or zoom in")
            } else {
                score += 0.1
                feedback.append("Good headroom")
            }
        }

        // Leading space (for faces with yaw)
        var leadingSpaceOk = true
        if let face = faces.first, let yaw = face.yaw {
            let lookingRight = yaw < 0
            let spaceRight = 1.0 - face.boundingBox.maxX
            let spaceLeft = face.boundingBox.minX
            if lookingRight && spaceRight < 0.15 {
                leadingSpaceOk = false
                feedback.append("Subject looking right but no leading space — move phone left")
            } else if !lookingRight && spaceLeft < 0.15 {
                leadingSpaceOk = false
                feedback.append("Subject looking left but no leading space — move phone right")
            } else {
                score += 0.1
            }
        }

        // Lighting
        switch scene.lighting {
        case .bright, .warm:
            score += 0.1
        case .dim:
            feedback.append("Low light — try moving to brighter area or use torch")
        case .dark:
            score -= 0.1
            feedback.append("Very dark — consider adding light source")
        case .backlit:
            feedback.append("Backlit subject — try repositioning or increase exposure")
        }

        let overallScore = max(0, min(1, score))
        let feedbackStr = feedback.isEmpty ? "Looks good!" : feedback.joined(separator: ". ")

        return CompositionInfo(
            ruleOfThirdsScore: ruleOfThirdsScore,
            headroomOk: headroomOk,
            leadingSpaceOk: leadingSpaceOk,
            overallScore: overallScore,
            feedback: feedbackStr
        )
    }

    // MARK: - Horizon Detection

    /// Horizon detection result.
    public struct HorizonInfo: Sendable {
        /// Angle of the horizon in degrees (0 = level, positive = tilted clockwise).
        public let angle: Float
        /// Whether the horizon is approximately level (within ±2°).
        public let isLevel: Bool
        /// Human-readable feedback.
        public let feedback: String
    }

    /// Detect the horizon angle in the current frame.
    public func detectHorizon(pixelBuffer: sending CVPixelBuffer) async -> HorizonInfo {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)
        return await Task.detached {
            let handler = VNImageRequestHandler(cvPixelBuffer: sendable.buffer, options: [:])
            let request = VNDetectHorizonRequest()
            try? handler.perform([request])

            if let result = request.results?.first {
                let degrees = Float(result.angle * 180 / .pi)
                let isLevel = abs(degrees) < 2.0
                let feedback: String
                if isLevel {
                    feedback = "Horizon is level"
                } else if degrees > 0 {
                    feedback = "Tilted \(String(format: "%.1f°", abs(degrees))) clockwise — rotate phone counter-clockwise"
                } else {
                    feedback = "Tilted \(String(format: "%.1f°", abs(degrees))) counter-clockwise — rotate phone clockwise"
                }
                return HorizonInfo(angle: degrees, isLevel: isLevel, feedback: feedback)
            }
            return HorizonInfo(angle: 0, isLevel: true, feedback: "No horizon detected")
        }.value
    }

    // MARK: - Blur Detection

    /// Blur detection result.
    public struct BlurInfo: Sendable {
        /// Sharpness score (0-1, higher = sharper).
        public let sharpness: Float
        /// Whether the image is acceptably sharp.
        public let isSharp: Bool
        /// Human-readable feedback.
        public let feedback: String
    }

    /// Detect blur/sharpness in the current frame using Laplacian variance.
    public func detectBlur(pixelBuffer: sending CVPixelBuffer) async -> BlurInfo {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)
        return await Task.detached {
            // Convert to grayscale and compute Laplacian variance
            let ciImage = CIImage(cvPixelBuffer: sendable.buffer)
            let context = CIContext()

            // Use CIImage Laplacian filter chain for blur detection
            guard let grayscale = CIFilter(name: "CIPhotoEffectMono", parameters: [kCIInputImageKey: ciImage])?.outputImage,
                  let edges = CIFilter(name: "CIEdges", parameters: [kCIInputImageKey: grayscale, "inputIntensity": 1.0])?.outputImage,
                  let cgImage = context.createCGImage(edges, from: edges.extent) else {
                return BlurInfo(sharpness: 0, isSharp: false, feedback: "Could not analyze sharpness")
            }

            // Sample edge intensity at grid points
            let width = cgImage.width
            let height = cgImage.height
            guard let data = cgImage.dataProvider?.data,
                  let ptr = CFDataGetBytePtr(data) else {
                return BlurInfo(sharpness: 0, isSharp: false, feedback: "Could not read pixel data")
            }

            let bytesPerRow = cgImage.bytesPerRow
            var totalIntensity: Double = 0
            let sampleStep = max(width / 30, 1)
            var samples = 0

            for y in stride(from: 0, to: height, by: sampleStep) {
                for x in stride(from: 0, to: width, by: sampleStep) {
                    let offset = y * bytesPerRow + x * 4
                    if offset + 2 < CFDataGetLength(data) {
                        let r = Double(ptr[offset])
                        let g = Double(ptr[offset + 1])
                        let b = Double(ptr[offset + 2])
                        totalIntensity += (r + g + b) / (3.0 * 255.0)
                        samples += 1
                    }
                }
            }

            let avgEdge = samples > 0 ? Float(totalIntensity / Double(samples)) : 0
            // Normalize: ~0.05 is very blurry, ~0.3+ is sharp
            let sharpness = min(1.0, avgEdge * 3.0)
            let isSharp = sharpness > 0.3

            let feedback: String
            if sharpness > 0.6 {
                feedback = "Very sharp image"
            } else if isSharp {
                feedback = "Acceptable sharpness"
            } else if sharpness > 0.15 {
                feedback = "Slightly blurry — hold phone steadier or tap to focus"
            } else {
                feedback = "Very blurry — stabilize phone and ensure subject is in focus"
            }

            return BlurInfo(sharpness: sharpness, isSharp: isSharp, feedback: feedback)
        }.value
    }

    // MARK: - Shot Type Classification

    /// Detected shot type.
    public enum ShotType: String, Sendable {
        case extremeCloseUp = "Extreme Close-Up"
        case closeUp = "Close-Up"
        case mediumCloseUp = "Medium Close-Up"
        case mediumShot = "Medium Shot"
        case mediumWide = "Medium Wide"
        case wideShot = "Wide Shot"
        case establishingShot = "Establishing Shot"
        case noSubject = "No Subject"
    }

    /// Scene type classification.
    public enum SceneType: String, Sendable {
        case talkingHead = "Talking Head"
        case interview = "Interview"
        case vlog = "Vlog"
        case productDemo = "Product Demo"
        case landscape = "Landscape"
        case action = "Action"
        case group = "Group Shot"
        case unknown = "Unknown"
    }

    /// Classify the current shot type based on face/subject size in frame.
    public func classifyShotType(faces: [DetectedFace]) -> ShotType {
        guard let face = faces.first else { return .noSubject }

        let faceWidth = face.boundingBox.width
        let faceHeight = face.boundingBox.height
        let faceArea = faceWidth * faceHeight

        // Shot type based on face size relative to frame
        if faceArea > 0.25 { return .extremeCloseUp }
        if faceArea > 0.12 { return .closeUp }
        if faceArea > 0.06 { return .mediumCloseUp }
        if faceArea > 0.02 { return .mediumShot }
        if faceArea > 0.005 { return .mediumWide }
        if faceArea > 0.001 { return .wideShot }
        return .establishingShot
    }

    /// Classify the scene type from combined analysis results.
    public func classifySceneType(scene: SceneContext, faces: [DetectedFace], poses: [DetectedPose]) -> SceneType {
        let faceCount = faces.count
        let hasPose = !poses.isEmpty

        // Multiple faces
        if faceCount >= 3 { return .group }

        // Two faces (interview setup)
        if faceCount == 2 { return .interview }

        // Single face
        if faceCount == 1 {
            guard let face = faces.first else { return .unknown }
            let faceArea = face.boundingBox.width * face.boundingBox.height

            // Large face, facing camera = talking head
            if faceArea > 0.05 {
                if let yaw = face.yaw, abs(yaw) < 0.3 {
                    return .talkingHead
                }
                return .vlog
            }

            // Smaller face with pose = vlog/action
            if hasPose { return .vlog }
        }

        // No faces: check scene labels
        let labels = Set(scene.sceneLabels)
        let outdoorLabels = Set(["sky", "cloud", "mountain", "ocean", "beach", "landscape", "sunset", "sunrise"])
        if !labels.isDisjoint(with: outdoorLabels) { return .landscape }

        let productLabels = Set(["table", "desk", "food", "drink", "package", "bottle"])
        if !labels.isDisjoint(with: productLabels) { return .productDemo }

        if hasPose { return .action }

        return .unknown
    }

    // MARK: - Rectangle Detection

    /// Detected rectangle in frame.
    public struct DetectedRectangle: Sendable {
        public let boundingBox: CGRect
        public let topLeft: CGPoint
        public let topRight: CGPoint
        public let bottomLeft: CGPoint
        public let bottomRight: CGPoint
        public let confidence: Float
    }

    /// Detect rectangles (documents, screens, products) in the current frame.
    public func detectRectangles(pixelBuffer: sending CVPixelBuffer) async -> [DetectedRectangle] {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)
        return await Task.detached {
            let handler = VNImageRequestHandler(cvPixelBuffer: sendable.buffer, options: [:])
            let request = VNDetectRectanglesRequest()
            request.minimumConfidence = 0.5
            request.maximumObservations = 5
            request.minimumAspectRatio = 0.3
            request.maximumAspectRatio = 1.0
            try? handler.perform([request])

            return (request.results ?? []).map { rect in
                DetectedRectangle(
                    boundingBox: rect.boundingBox,
                    topLeft: rect.topLeft,
                    topRight: rect.topRight,
                    bottomLeft: rect.bottomLeft,
                    bottomRight: rect.bottomRight,
                    confidence: rect.confidence
                )
            }
        }.value
    }

    // MARK: - Subject Tracking

    /// Track a rectangular region across frames.
    /// Returns updated bounding box after tracking.
    public func trackSubject(initialBBox: CGRect, in pixelBuffer: sending CVPixelBuffer) async -> CGRect? {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)
        let bbox = initialBBox
        return await Task.detached {
            let observation = VNDetectedObjectObservation(boundingBox: bbox)
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .fast
            let handler = VNSequenceRequestHandler()
            try? handler.perform([request], on: sendable.buffer)

            if let result = request.results?.first as? VNDetectedObjectObservation {
                return result.boundingBox
            }
            return nil
        }.value
    }

    // MARK: - Face Expression Detection

    /// Detected face with expression details.
    public struct FaceExpression: Sendable {
        public let boundingBox: CGRect
        public let confidence: Float
        public let roll: CGFloat?
        public let yaw: CGFloat?
        public let isSmiling: Bool
        public let leftEyeClosed: Bool
        public let rightEyeClosed: Bool
        public let mouthOpen: Bool
        public let lookingLeft: Bool
        public let lookingRight: Bool
        public let facingCamera: Bool

        public var expressionDescription: String {
            var parts: [String] = []
            if isSmiling { parts.append("smiling") }
            if leftEyeClosed && rightEyeClosed { parts.append("eyes closed") }
            else if leftEyeClosed || rightEyeClosed { parts.append("winking") }
            if mouthOpen { parts.append("mouth open") }
            if lookingLeft { parts.append("looking left") }
            else if lookingRight { parts.append("looking right") }
            else if facingCamera { parts.append("facing camera") }
            return parts.isEmpty ? "neutral" : parts.joined(separator: ", ")
        }
    }

    /// Detect faces with detailed expressions (smile, blink, mouth, gaze direction).
    public func detectFaceExpressions(pixelBuffer: sending CVPixelBuffer) async -> [FaceExpression] {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)
        return await Task.detached {
            let handler = VNImageRequestHandler(cvPixelBuffer: sendable.buffer, options: [:])
            let request = VNDetectFaceLandmarksRequest()
            try? handler.perform([request])

            return (request.results ?? []).map { face -> FaceExpression in
                let landmarks = face.landmarks

                // Detect smile: compare mouth width to face width
                let isSmiling: Bool = {
                    guard let outerLips = landmarks?.outerLips,
                          let points = outerLips.normalizedPoints as? [CGPoint],
                          points.count >= 4 else { return false }
                    // Smile heuristic: wide mouth relative to face
                    let mouthWidth = points.map(\.x).max()! - points.map(\.x).min()!
                    return mouthWidth > 0.45 // normalized to face bbox
                }()

                // Detect eye closure: check if eye height is minimal
                let leftEyeClosed: Bool = {
                    guard let leftEye = landmarks?.leftEye,
                          let points = leftEye.normalizedPoints as? [CGPoint],
                          points.count >= 4 else { return false }
                    let eyeHeight = points.map(\.y).max()! - points.map(\.y).min()!
                    return eyeHeight < 0.15
                }()

                let rightEyeClosed: Bool = {
                    guard let rightEye = landmarks?.rightEye,
                          let points = rightEye.normalizedPoints as? [CGPoint],
                          points.count >= 4 else { return false }
                    let eyeHeight = points.map(\.y).max()! - points.map(\.y).min()!
                    return eyeHeight < 0.15
                }()

                // Detect mouth open
                let mouthOpen: Bool = {
                    guard let innerLips = landmarks?.innerLips,
                          let points = innerLips.normalizedPoints as? [CGPoint],
                          points.count >= 4 else { return false }
                    let mouthHeight = points.map(\.y).max()! - points.map(\.y).min()!
                    return mouthHeight > 0.15
                }()

                // Gaze direction from yaw
                let yawValue = face.yaw.flatMap { CGFloat($0.doubleValue) }
                let lookingLeft = (yawValue ?? 0) > 0.2
                let lookingRight = (yawValue ?? 0) < -0.2
                let facingCamera = !lookingLeft && !lookingRight

                return FaceExpression(
                    boundingBox: face.boundingBox,
                    confidence: face.confidence,
                    roll: face.roll.flatMap { CGFloat($0.doubleValue) },
                    yaw: yawValue,
                    isSmiling: isSmiling,
                    leftEyeClosed: leftEyeClosed,
                    rightEyeClosed: rightEyeClosed,
                    mouthOpen: mouthOpen,
                    lookingLeft: lookingLeft,
                    lookingRight: lookingRight,
                    facingCamera: facingCamera
                )
            }
        }.value
    }

    // MARK: - Animal Detection

    /// Detected animal in frame.
    public struct DetectedAnimal: Sendable {
        public let label: String  // "Cat" or "Dog"
        public let confidence: Float
        public let boundingBox: CGRect
    }

    /// Detect animals (cats, dogs) in the current frame.
    public func detectAnimals(pixelBuffer: sending CVPixelBuffer) async -> [DetectedAnimal] {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)
        return await Task.detached {
            let handler = VNImageRequestHandler(cvPixelBuffer: sendable.buffer, options: [:])
            let request = VNRecognizeAnimalsRequest()
            try? handler.perform([request])

            return (request.results ?? []).flatMap { observation in
                observation.labels.map { label in
                    DetectedAnimal(
                        label: label.identifier,
                        confidence: label.confidence,
                        boundingBox: observation.boundingBox
                    )
                }
            }
        }.value
    }

    // MARK: - Rich Environment Description

    /// Comprehensive environment analysis combining multiple Vision passes.
    public struct EnvironmentDescription: Sendable {
        public let sceneLabels: [String]
        public let lighting: Lighting
        public let recognizedTexts: [String]
        public let faceCount: Int
        public let faceExpressions: [String]
        public let animalCount: Int
        public let animalTypes: [String]
        public let poseCount: Int
        public let poseDescriptions: [String]
        public let objectCount: Int
        public let objectLabels: [String]
        public let isSharp: Bool
        public let isLevel: Bool
        public let composition: String

        public var description: String {
            var parts: [String] = []
            parts.append("Scene: \(sceneLabels.prefix(5).joined(separator: ", "))")
            parts.append("Lighting: \(lighting.rawValue)")
            if !recognizedTexts.isEmpty { parts.append("Text: \(recognizedTexts.prefix(3).joined(separator: ", "))") }
            if faceCount > 0 { parts.append("Faces: \(faceCount) (\(faceExpressions.joined(separator: "; ")))") }
            if animalCount > 0 { parts.append("Animals: \(animalTypes.joined(separator: ", "))") }
            if poseCount > 0 { parts.append("People: \(poseCount) (\(poseDescriptions.prefix(2).joined(separator: "; ")))") }
            parts.append("Sharp: \(isSharp ? "yes" : "no"), Level: \(isLevel ? "yes" : "no")")
            parts.append("Composition: \(composition)")
            return parts.joined(separator: "\n")
        }
    }

    /// Full environment analysis — runs all detectors and produces a rich description.
    public func describeEnvironment(pixelBuffer: sending CVPixelBuffer) async -> EnvironmentDescription {
        let sendable = SendablePixelBuffer(buffer: pixelBuffer)

        let scene = await analyze(pixelBuffer: sendable.buffer) ?? SceneContext(
            sceneLabels: [], recognizedTexts: [], aestheticScore: 0,
            lighting: .bright, focalPoints: [], timestamp: Date()
        )
        let faces = await detectFaceExpressions(pixelBuffer: sendable.buffer)
        let animals = await detectAnimals(pixelBuffer: sendable.buffer)
        let poses = await detectPoses(pixelBuffer: sendable.buffer)
        let objects = await detectObjects(pixelBuffer: sendable.buffer)
        let blur = await detectBlur(pixelBuffer: sendable.buffer)
        let horizon = await detectHorizon(pixelBuffer: sendable.buffer)

        // Describe poses
        let poseDescs: [String] = poses.prefix(3).map { pose in
            let hasArmsUp = (pose.joints["right_wrist_joint"]?.y ?? 0) > (pose.joints["right_shoulder_joint"]?.y ?? 1)
                || (pose.joints["left_wrist_joint"]?.y ?? 0) > (pose.joints["left_shoulder_joint"]?.y ?? 1)
            if hasArmsUp { return "arms raised" }
            return "standing"
        }

        // Composition feedback
        let simpleFaces = faces.map { DetectedFace(boundingBox: $0.boundingBox, confidence: $0.confidence, roll: $0.roll, yaw: $0.yaw) }
        let comp = evaluateComposition(scene: scene, faces: simpleFaces, poses: poses)

        return EnvironmentDescription(
            sceneLabels: scene.sceneLabels,
            lighting: scene.lighting,
            recognizedTexts: scene.recognizedTexts,
            faceCount: faces.count,
            faceExpressions: faces.map { $0.expressionDescription },
            animalCount: animals.count,
            animalTypes: animals.map { $0.label },
            poseCount: poses.count,
            poseDescriptions: poseDescs,
            objectCount: objects.count,
            objectLabels: objects.map { $0.label },
            isSharp: blur.isSharp,
            isLevel: horizon.isLevel,
            composition: comp.feedback
        )
    }
}
#endif
