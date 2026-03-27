#if canImport(ARKit) && !targetEnvironment(simulator)
import ARKit
import CoreVideo

/// Performs a brief ARKit scan to understand the 3D environment.
/// Collects planes (floor, walls, ceiling, table, etc.), mesh classifications,
/// lighting estimation, and depth data.
///
/// Usage: Call `scan(duration:)` to get a snapshot. This will temporarily use the
/// back camera — the caller is responsible for pausing/resuming AVCaptureSession.
@MainActor
public final class ARSceneUnderstanding: NSObject, ObservableObject {

    // MARK: - Public types

    public struct PlaneInfo: Sendable {
        public let classification: String      // "floor", "wall", "ceiling", etc.
        public let widthMeters: Float
        public let heightMeters: Float
        public let centerPosition: SIMD3<Float>
    }

    public struct EnvironmentSnapshot: Sendable {
        public let planes: [PlaneInfo]
        public let meshClassificationCounts: [String: Int]  // "wall" -> 142 faces, etc.
        public let totalMeshVertices: Int
        public let ambientIntensityLumens: Float
        public let colorTemperatureKelvin: Float
        public let depthRangeMeters: (min: Float, max: Float)?
        public let hasLiDAR: Bool
        public let scanDurationSeconds: Double

        public var description: String {
            var parts: [String] = []

            // Surfaces
            if !planes.isEmpty {
                let grouped = Dictionary(grouping: planes, by: { $0.classification })
                let surfaceDesc = grouped.map { key, items in
                    if items.count == 1 {
                        let p = items[0]
                        return "\(key) (\(String(format: "%.1f", p.widthMeters))×\(String(format: "%.1f", p.heightMeters))m)"
                    } else {
                        return "\(key) ×\(items.count)"
                    }
                }.joined(separator: ", ")
                parts.append("Surfaces: \(surfaceDesc)")
            } else {
                parts.append("Surfaces: none detected (need more time or LiDAR)")
            }

            // Mesh
            if totalMeshVertices > 0 {
                let meshDesc = meshClassificationCounts.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                parts.append("3D mesh: \(totalMeshVertices) vertices — \(meshDesc)")
            }

            // Lighting
            parts.append("Lighting: \(Int(ambientIntensityLumens)) lumens, \(Int(colorTemperatureKelvin))K color temp")

            // Depth
            if let depth = depthRangeMeters {
                parts.append("Depth range: \(String(format: "%.1f", depth.min))m – \(String(format: "%.1f", depth.max))m")
            }

            // Room estimate
            let floors = planes.filter { $0.classification == "floor" }
            let ceilings = planes.filter { $0.classification == "ceiling" }
            let walls = planes.filter { $0.classification == "wall" }
            if !floors.isEmpty || !walls.isEmpty {
                var roomParts: [String] = []
                if let floor = floors.first {
                    roomParts.append("floor ~\(String(format: "%.1f", floor.widthMeters))×\(String(format: "%.1f", floor.heightMeters))m")
                }
                if !walls.isEmpty {
                    roomParts.append("\(walls.count) walls")
                }
                if let ceiling = ceilings.first {
                    let floorY = floors.first?.centerPosition.y ?? 0
                    let height = ceiling.centerPosition.y - floorY
                    if height > 0.5 {
                        roomParts.append("~\(String(format: "%.1f", height))m ceiling height")
                    }
                }
                parts.append("Room: \(roomParts.joined(separator: ", "))")
            }

            parts.append("LiDAR: \(hasLiDAR ? "yes" : "no"), scan: \(String(format: "%.1f", scanDurationSeconds))s")
            return parts.joined(separator: "\n")
        }
    }

    // MARK: - Private state

    private var session: ARSession?
    private var collectedPlanes: [PlaneInfo] = []
    private var meshCounts: [String: Int] = [:]
    private var meshVertexCount: Int = 0
    private var lastLightIntensity: Float = 1000
    private var lastColorTemp: Float = 6500
    private var depthMin: Float = Float.greatestFiniteMagnitude
    private var depthMax: Float = 0
    private var hasDepth = false
    private var hasLiDAR = false

    // MARK: - Public API

    /// Check if ARKit world tracking is supported on this device.
    public static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    /// Perform a brief ARKit scan and return environment data.
    /// The caller MUST stop AVCaptureSession before calling this.
    /// - Parameter duration: How long to scan in seconds. 2-3s is usually enough for planes.
    public func scan(duration: TimeInterval = 3.0) async -> EnvironmentSnapshot {
        guard Self.isSupported else {
            return EnvironmentSnapshot(
                planes: [], meshClassificationCounts: [:], totalMeshVertices: 0,
                ambientIntensityLumens: 0, colorTemperatureKelvin: 0,
                depthRangeMeters: nil, hasLiDAR: false, scanDurationSeconds: 0
            )
        }

        // Reset state
        collectedPlanes = []
        meshCounts = [:]
        meshVertexCount = 0
        depthMin = Float.greatestFiniteMagnitude
        depthMax = 0
        hasDepth = false

        // Configure ARSession
        let arSession = ARSession()
        arSession.delegate = self
        self.session = arSession

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic

        // Enable scene reconstruction if LiDAR is available
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
            hasLiDAR = true
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            hasLiDAR = true
        } else {
            hasLiDAR = false
        }

        // Enable depth if available
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        print("[ARScene] Starting AR scan for \(duration)s, LiDAR: \(hasLiDAR)")
        arSession.run(config)

        // Wait for the scan duration
        try? await Task.sleep(for: .seconds(duration))

        // Collect final state from anchors
        collectPlanesFromAnchors(arSession.currentFrame?.anchors ?? [])
        collectMeshFromAnchors(arSession.currentFrame?.anchors ?? [])

        // Get final light estimate
        if let light = arSession.currentFrame?.lightEstimate {
            lastLightIntensity = Float(light.ambientIntensity)
            lastColorTemp = Float(light.ambientColorTemperature)
        }

        // Get depth range
        if let depthMap = arSession.currentFrame?.sceneDepth?.depthMap {
            analyzeDepthMap(depthMap)
        }

        // Stop AR session
        arSession.pause()
        self.session = nil
        print("[ARScene] Scan complete. Planes: \(collectedPlanes.count), Vertices: \(meshVertexCount)")

        return EnvironmentSnapshot(
            planes: collectedPlanes,
            meshClassificationCounts: meshCounts,
            totalMeshVertices: meshVertexCount,
            ambientIntensityLumens: lastLightIntensity,
            colorTemperatureKelvin: lastColorTemp,
            depthRangeMeters: hasDepth ? (depthMin, depthMax) : nil,
            hasLiDAR: hasLiDAR,
            scanDurationSeconds: duration
        )
    }

    // MARK: - Private helpers

    private func collectPlanesFromAnchors(_ anchors: [ARAnchor]) {
        collectedPlanes = anchors.compactMap { anchor -> PlaneInfo? in
            guard let plane = anchor as? ARPlaneAnchor else { return nil }
            let classStr: String
            switch plane.classification {
            case .wall: classStr = "wall"
            case .floor: classStr = "floor"
            case .ceiling: classStr = "ceiling"
            case .table: classStr = "table"
            case .seat: classStr = "seat"
            case .door: classStr = "door"
            case .window: classStr = "window"
            case .none: classStr = "unknown"
            @unknown default: classStr = "other"
            }
            return PlaneInfo(
                classification: classStr,
                widthMeters: plane.extent.x,
                heightMeters: plane.extent.z,
                centerPosition: plane.center
            )
        }
    }

    private func collectMeshFromAnchors(_ anchors: [ARAnchor]) {
        meshCounts = [:]
        meshVertexCount = 0

        for anchor in anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            meshVertexCount += mesh.geometry.vertices.count

            // Count face classifications
            if let classBuffer = mesh.geometry.classification {
                let count = classBuffer.count
                let ptr = classBuffer.buffer.contents().bindMemory(to: UInt8.self, capacity: count)
                for i in 0..<count {
                    let rawValue = ptr[i]
                    let label: String
                    switch ARMeshClassification(rawValue: Int(rawValue)) {
                    case .wall: label = "wall"
                    case .floor: label = "floor"
                    case .ceiling: label = "ceiling"
                    case .table: label = "table"
                    case .seat: label = "seat"
                    case .door: label = "door"
                    case .window: label = "window"
                    case .none: label = "none"
                    default: label = "other"
                    }
                    meshCounts[label, default: 0] += 1
                }
            }
        }
    }

    private func analyzeDepthMap(_ depthMap: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }

        let floatPtr = base.assumingMemoryBound(to: Float32.self)
        let rowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size

        // Sample grid points for depth range
        for y in Swift.stride(from: 0, to: height, by: max(1, height / 20)) {
            for x in Swift.stride(from: 0, to: width, by: max(1, width / 20)) {
                let depth = floatPtr[y * rowStride + x]
                if depth > 0 && depth < 100 {  // Valid range
                    depthMin = min(depthMin, depth)
                    depthMax = max(depthMax, depth)
                    hasDepth = true
                }
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension ARSceneUnderstanding: ARSessionDelegate {
    nonisolated public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Light estimation updates continuously
        if let light = frame.lightEstimate {
            Task { @MainActor in
                self.lastLightIntensity = Float(light.ambientIntensity)
                self.lastColorTemp = Float(light.ambientColorTemperature)
            }
        }
    }

    nonisolated public func session(_ session: ARSession, didFailWithError error: Error) {
        print("[ARScene] Session failed: \(error)")
    }
}
#endif
