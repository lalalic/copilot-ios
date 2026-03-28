#if os(iOS)
import Foundation
import UIKit
import QuartzCore

// MARK: - Animation Easing

/// Easing functions for camera parameter interpolation.
public enum AnimationEasing: Sendable {
    case linear
    case easeIn        // slow start
    case easeOut       // slow end
    case easeInOut     // slow start + slow end
    case spring(damping: Double, stiffness: Double)

    /// Map normalized time t (0...1) through easing curve → 0...1.
    public func apply(_ t: Double) -> Double {
        let t = max(0, min(1, t))
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t * t
        case .easeOut:
            let inv = 1 - t
            return 1 - inv * inv * inv
        case .easeInOut:
            if t < 0.5 {
                return 4 * t * t * t
            } else {
                let p = -2 * t + 2
                return 1 - p * p * p / 2
            }
        case .spring(let damping, let stiffness):
            // Critically-damped spring approximation
            let omega = sqrt(stiffness)
            let zeta = damping / (2 * omega)
            if zeta >= 1 {
                // Over-damped → ease-out fallback
                let inv = 1 - t
                return 1 - inv * inv
            }
            let wd = omega * sqrt(1 - zeta * zeta)
            let envelope = exp(-zeta * omega * t * 3) // scale time for visible effect
            return 1 - envelope * cos(wd * t * 3)
        }
    }

    /// Parse from string name used in tool JSON.
    public static func from(string: String, damping: Double? = nil, stiffness: Double? = nil) -> AnimationEasing {
        switch string.lowercased() {
        case "ease_in", "easein": return .easeIn
        case "ease_out", "easeout": return .easeOut
        case "ease_in_out", "easeinout": return .easeInOut
        case "spring":
            return .spring(damping: damping ?? 0.7, stiffness: stiffness ?? 100)
        default: return .linear
        }
    }
}

// MARK: - Camera Keyframe

/// A snapshot of camera parameter values at a specific time.
/// Only non-nil parameters are animated; others remain at their current value.
public struct CameraKeyframe: Sendable {
    /// Time in seconds from animation start.
    public let time: Double

    /// Easing to use when interpolating FROM this keyframe TO the next.
    public let easing: AnimationEasing

    // Animatable camera parameters (nil = don't change)
    public let zoom: Double?
    public let exposure: Double?       // EV compensation (-2 to +2)
    public let focusX: Double?         // 0-1 normalized
    public let focusY: Double?         // 0-1 normalized
    public let whiteBalance: Double?   // Kelvin (0 = auto, not animatable per se)
    public let iso: Double?            // Manual ISO
    public let shutterSpeed: Double?   // Manual shutter in seconds

    public init(
        time: Double,
        easing: AnimationEasing = .linear,
        zoom: Double? = nil,
        exposure: Double? = nil,
        focusX: Double? = nil,
        focusY: Double? = nil,
        whiteBalance: Double? = nil,
        iso: Double? = nil,
        shutterSpeed: Double? = nil
    ) {
        self.time = time
        self.easing = easing
        self.zoom = zoom
        self.exposure = exposure
        self.focusX = focusX
        self.focusY = focusY
        self.whiteBalance = whiteBalance
        self.iso = iso
        self.shutterSpeed = shutterSpeed
    }
}

// MARK: - Camera Animator

/// Animates camera parameters over time using keyframes and easing curves.
/// Uses CADisplayLink for smooth, frame-accurate interpolation.
@MainActor
public final class CameraAnimator: NSObject {

    private let camera: CameraService
    private var keyframes: [CameraKeyframe] = []
    private var duration: Double = 0
    private var startTime: CFTimeInterval = 0

    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private var completion: (() -> Void)?

    /// Whether an animation is currently running.
    public private(set) var isAnimating = false

    public init(camera: CameraService) {
        self.camera = camera
        super.init()
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Public API

    /// Start animating camera parameters through the given keyframes.
    /// - Parameters:
    ///   - keyframes: Array of keyframes sorted by time. First keyframe should be at time 0.
    ///   - duration: Total animation duration in seconds. If nil, uses the last keyframe's time.
    /// - Returns: Async — suspends until animation completes.
    public func animate(keyframes: [CameraKeyframe], duration: Double? = nil) async {
        // Sort keyframes by time
        self.keyframes = keyframes.sorted { $0.time < $1.time }
        guard !self.keyframes.isEmpty else { return }

        self.duration = duration ?? (self.keyframes.last?.time ?? 0)
        guard self.duration > 0 else {
            // Just apply the single keyframe immediately
            if let kf = self.keyframes.first {
                applyValues(kf)
            }
            return
        }

        // Apply first keyframe immediately
        applyValues(self.keyframes[0])

        await withCheckedContinuation { cont in
            self.completion = { cont.resume() }
            self.isAnimating = true
            self.startTime = CACurrentMediaTime()

            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
    }

    /// Stop the current animation immediately.
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isAnimating = false
        let c = completion
        completion = nil
        c?()
    }

    // MARK: - Display Link Tick

    @objc private func tick() {
        let elapsed = CACurrentMediaTime() - startTime
        let progress = min(elapsed / duration, 1.0)

        // Find surrounding keyframes
        let currentTime = progress * duration
        let interpolated = interpolateKeyframes(at: currentTime)
        applyValues(interpolated)

        if progress >= 1.0 {
            stop()
        }
    }

    // MARK: - Interpolation

    /// Interpolate between keyframes at the given time.
    private func interpolateKeyframes(at time: Double) -> CameraKeyframe {
        guard keyframes.count >= 2 else {
            return keyframes.first ?? CameraKeyframe(time: 0)
        }

        // Find the two bracketing keyframes
        var lower = keyframes[0]
        var upper = keyframes[keyframes.count - 1]

        for i in 0..<(keyframes.count - 1) {
            if keyframes[i].time <= time && keyframes[i + 1].time >= time {
                lower = keyframes[i]
                upper = keyframes[i + 1]
                break
            }
        }

        // If before first keyframe, use first
        if time <= lower.time { return lower }
        // If after last keyframe, use last
        if time >= upper.time { return upper }

        // Normalized progress within this segment
        let segmentDuration = upper.time - lower.time
        let segmentProgress = segmentDuration > 0 ? (time - lower.time) / segmentDuration : 1.0

        // Apply the easing from the lower keyframe
        let easedT = lower.easing.apply(segmentProgress)

        return CameraKeyframe(
            time: time,
            easing: lower.easing,
            zoom: lerp(lower.zoom, upper.zoom, easedT),
            exposure: lerp(lower.exposure, upper.exposure, easedT),
            focusX: lerp(lower.focusX, upper.focusX, easedT),
            focusY: lerp(lower.focusY, upper.focusY, easedT),
            whiteBalance: lerp(lower.whiteBalance, upper.whiteBalance, easedT),
            iso: lerp(lower.iso, upper.iso, easedT),
            shutterSpeed: lerp(lower.shutterSpeed, upper.shutterSpeed, easedT)
        )
    }

    /// Linear interpolation between two optional values.
    /// If either is nil, returns the non-nil one (or nil if both).
    private func lerp(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        switch (a, b) {
        case (.some(let a), .some(let b)):
            return a + (b - a) * t
        case (.some(let a), .none):
            return a
        case (.none, .some(let b)):
            return b
        case (.none, .none):
            return nil
        }
    }

    // MARK: - Apply Values

    /// Apply interpolated values to the camera.
    private func applyValues(_ kf: CameraKeyframe) {
        if let zoom = kf.zoom {
            camera.setZoom(CGFloat(zoom))
        }
        if let exposure = kf.exposure {
            camera.setExposure(Float(exposure))
        }
        if let focusX = kf.focusX, let focusY = kf.focusY {
            camera.setFocus(x: Float(focusX), y: Float(focusY))
        }
        if let whiteBalance = kf.whiteBalance {
            if whiteBalance == 0 {
                camera.setWhiteBalanceAuto()
            } else {
                camera.setWhiteBalance(temperature: Float(whiteBalance))
            }
        }
        if kf.iso != nil || kf.shutterSpeed != nil {
            camera.setManualExposure(
                iso: kf.iso.map { Float($0) },
                shutterSpeed: kf.shutterSpeed
            )
        }
    }
}
#endif
