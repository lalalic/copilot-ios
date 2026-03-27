#if os(iOS)
import SwiftUI
import AVFoundation

// MARK: - Camera Preview

/// UIView subclass that keeps preview layer sized correctly.
public class CameraPreviewUIView: UIView {
    public var previewLayer: AVCaptureVideoPreviewLayer?

    override public func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

/// SwiftUI wrapper for live camera preview.
public struct CameraPreview: UIViewRepresentable {
    public let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        view.previewLayer = previewLayer
        return view
    }

    public func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer?.frame = uiView.bounds
    }
}

// MARK: - Sendable Pixel Buffer

/// Sendable wrapper for CVPixelBuffer (safe after copying).
public struct SendablePixelBuffer: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public init(buffer: CVPixelBuffer) { self.buffer = buffer }
}

// MARK: - Frame Delegate

/// Delegate protocol for receiving video frames.
@MainActor
public protocol CameraFrameDelegate: AnyObject {
    func cameraService(_ service: CameraService, didCaptureFrame pixelBuffer: SendablePixelBuffer)
}

// MARK: - Camera Service

/// Manages AVCaptureSession for preview, recording, frame analysis, and camera controls.
@MainActor
public final class CameraService: NSObject, ObservableObject, @unchecked Sendable {
    @Published public var isRunning = false
    @Published public var isAuthorized = false
    @Published private var _isRecording = false
    
    /// Recording state — checks MultiCamService when PiP is active.
    public var isRecording: Bool {
        get {
            if let mcs = multiCamService, mcs.isRunning {
                return mcs.isRecording
            }
            return _isRecording
        }
        set { _isRecording = newValue }
    }
    @Published public var currentCameraPosition: AVCaptureDevice.Position = .back
    @Published public var currentZoom: CGFloat = 1.0

    public weak var frameDelegate: CameraFrameDelegate?

    public let session = AVCaptureSession()
    private var hasConfigured = false
    private let queue = DispatchQueue(label: "camerakit.session")

    // Outputs
    private var movieOutput: AVCaptureMovieFileOutput?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var recordingDelegate: RecordingDelegate?
    private var currentRecordingURL: URL?
    private var recordingCompletion: ((URL?) -> Void)?

    // Frame sampling
    nonisolated(unsafe) private var lastFrameTime: CFTimeInterval = 0

    /// Frame interval for delegate callbacks (seconds). Default 1.0.
    nonisolated(unsafe) public var frameInterval: CFTimeInterval = 1.0

    // Latest captured frame as base64 JPEG (for AI observation)
    private var latestFrameBase64: String?
    /// Backing store for latest pixel buffer from camera.
    private var _latestPixelBuffer: CVPixelBuffer?
    
    /// Latest pixel buffer — routes through MultiCamService when PiP is active.
    public var latestPixelBuffer: CVPixelBuffer? {
        get {
            if let mcs = multiCamService, mcs.isRunning, let buf = mcs.latestPixelBuffer {
                return buf
            }
            return _latestPixelBuffer
        }
        set { _latestPixelBuffer = newValue }
    }
    private var pendingPhotoContinuation: CheckedContinuation<UIImage?, Never>?
    
    /// Reference to MultiCamService for PiP mode routing.
    /// When set and running, recording/capture/frame operations route through it.
    public var multiCamService: MultiCamService?
    
    /// Whether operations should route through MultiCamService.
    public var isPiPActive: Bool {
        multiCamService?.isRunning == true
    }

    public override init() {
        super.init()
    }

    // MARK: - Authorization & Session Lifecycle

    public func requestAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            startSession()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                isAuthorized = granted
                if granted { startSession() }
            }
        default:
            isAuthorized = false
        }
    }

    public func startSession() {
        guard !hasConfigured else {
            if !isRunning {
                let s = session
                queue.async { s.startRunning() }
                isRunning = true
            }
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("CameraKit: Audio session setup error: \(error)")
        }

        session.beginConfiguration()
        session.sessionPreset = .high

        // Camera input
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        // Audio input (add upfront so recording doesn't need to reconfigure)
        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        // Movie file output
        let movieOutput = AVCaptureMovieFileOutput()
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            self.movieOutput = movieOutput
        }

        // Video data output (frame sampling)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        let sampleQueue = DispatchQueue(label: "camerakit.sample")
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            self.videoDataOutput = videoOutput
        }

        session.commitConfiguration()
        hasConfigured = true

        let s = session
        queue.async { s.startRunning() }
        isRunning = true
    }

    public func stopSession() {
        // Cancel any pending photo capture continuation to avoid leaks
        if let cont = pendingPhotoContinuation {
            pendingPhotoContinuation = nil
            cont.resume(returning: nil)
        }
        if isRunning {
            let s = session
            queue.async { s.stopRunning() }
            isRunning = false
        }
    }

    // MARK: - Recording

    @discardableResult
    public func startRecording() -> URL? {
        // Route through MultiCamService when PiP is active
        if let mcs = multiCamService, mcs.isRunning {
            print("[CameraService] PiP active — routing startRecording to MultiCamService")
            return mcs.startRecording()
        }
        print("[CameraService] startRecording() called. movieOutput=\(movieOutput != nil), isRecording=\(isRecording)")
        guard let movieOutput, !isRecording else {
            print("[CameraService] startRecording() guard failed")
            return nil
        }

        print("[CameraService] session.isRunning=\(session.isRunning), inputs=\(session.inputs.count), outputs=\(session.outputs.count)")

        let fileName = "camerakit_\(UUID().uuidString.prefix(8)).mov"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        currentRecordingURL = url

        let delegate = RecordingDelegate { [weak self] url in
            Task { @MainActor [weak self] in
                self?.isRecording = false
                self?.recordingCompletion?(url)
                self?.recordingCompletion = nil
            }
        }
        recordingDelegate = delegate
        print("[CameraService] About to call movieOutput.startRecording(to: \(url.lastPathComponent))")
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
        print("[CameraService] movieOutput.startRecording() returned")
        isRecording = true
        return url
    }

    public func stopRecording(completion: @escaping (URL?) -> Void) {
        // Route through MultiCamService when PiP is active
        if let mcs = multiCamService, mcs.isRunning {
            print("[CameraService] PiP active — routing stopRecording to MultiCamService")
            Task {
                let url = await mcs.stopRecording()
                completion(url)
            }
            return
        }
        guard let movieOutput, isRecording else {
            completion(nil)
            return
        }
        recordingCompletion = { url in
            completion(url)
        }
        movieOutput.stopRecording()
    }

    /// Async version of stopRecording.
    public func stopRecording() async -> URL? {
        await withCheckedContinuation { continuation in
            stopRecording { url in
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: - Camera Switching

    public func switchCamera() {
        let newPosition: AVCaptureDevice.Position = currentCameraPosition == .back ? .front : .back

        session.beginConfiguration()
        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput,
               deviceInput.device.hasMediaType(.video) {
                session.removeInput(deviceInput)
            }
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }

        session.addInput(input)
        session.commitConfiguration()
        currentCameraPosition = newPosition
    }

    /// Switch to front camera (no-op if already on front).
    public func switchToFrontCamera() {
        if currentCameraPosition != .front { switchCamera() }
    }

    /// Switch to back camera (no-op if already on back).
    public func switchToBackCamera() {
        if currentCameraPosition != .back { switchCamera() }
    }

    // MARK: - Camera Controls

    /// Set zoom level. Ranges from 1.0 to device max.
    public func setZoom(_ factor: CGFloat) {
        guard let device = currentVideoDevice else { return }
        let clamped = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            currentZoom = clamped
        } catch {
            print("CameraKit: Zoom error: \(error)")
        }
    }

    /// Set exposure compensation (-2.0 to +2.0 EV).
    public func setExposure(_ bias: Float) {
        guard let device = currentVideoDevice else { return }
        let clamped = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(clamped)
            device.unlockForConfiguration()
        } catch {
            print("CameraKit: Exposure error: \(error)")
        }
    }

    /// Set focus point (normalized 0-1 coordinates).
    public func setFocus(x: Float, y: Float) {
        guard let device = currentVideoDevice, device.isFocusPointOfInterestSupported else { return }
        let point = CGPoint(x: CGFloat(max(0, min(1, x))), y: CGFloat(max(0, min(1, y))))
        do {
            try device.lockForConfiguration()
            device.focusPointOfInterest = point
            device.focusMode = .autoFocus
            device.unlockForConfiguration()
        } catch {
            print("CameraKit: Focus error: \(error)")
        }
    }

    /// Set flash/torch mode.
    public func setFlash(_ mode: FlashMode) {
        guard let device = currentVideoDevice else { return }
        do {
            try device.lockForConfiguration()
            switch mode {
            case .off:
                if device.hasTorch { device.torchMode = .off }
            case .on:
                if device.hasTorch { device.torchMode = .on }
            case .auto:
                if device.hasTorch { device.torchMode = .auto }
            case .torch:
                if device.hasTorch { try device.setTorchModeOn(level: 1.0) }
            }
            device.unlockForConfiguration()
        } catch {
            print("CameraKit: Flash error: \(error)")
        }
    }

    public enum FlashMode: String, Sendable {
        case off, on, auto, torch
    }

    /// Available lens types.
    public enum LensType: String, Sendable {
        case wide, ultraWide, telephoto
    }

    /// Set camera with specific position and lens type.
    public func setCamera(position: AVCaptureDevice.Position? = nil, lens: LensType = .wide) {
        let pos = position ?? currentCameraPosition
        print("[CameraService] setCamera(position: \(pos == .front ? "front" : "back"), lens: \(lens))")

        let deviceType: AVCaptureDevice.DeviceType
        switch lens {
        case .wide: deviceType = .builtInWideAngleCamera
        case .ultraWide: deviceType = .builtInUltraWideCamera
        case .telephoto: deviceType = .builtInTelephotoCamera
        }

        session.beginConfiguration()
        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput,
               deviceInput.device.hasMediaType(.video) {
                session.removeInput(deviceInput)
            }
        }

        guard let camera = AVCaptureDevice.default(deviceType, for: .video, position: pos),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            // Fallback to wide angle
            if lens != .wide, let fallback = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos),
               let input = try? AVCaptureDeviceInput(device: fallback),
               session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            return
        }

        session.addInput(input)
        session.commitConfiguration()
        currentCameraPosition = pos
    }

    /// Get available lens types for current position.
    public func availableLenses(for position: AVCaptureDevice.Position? = nil) -> [LensType] {
        let pos = position ?? currentCameraPosition
        var lenses: [LensType] = []
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos) != nil { lenses.append(.wide) }
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: pos) != nil { lenses.append(.ultraWide) }
        if AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: pos) != nil { lenses.append(.telephoto) }
        return lenses
    }

    /// Set manual exposure with ISO and shutter speed.
    /// - Parameters:
    ///   - iso: ISO sensitivity (e.g. 100-3200). Pass nil to keep current.
    ///   - shutterSpeed: Shutter speed in seconds (e.g. 0.001 for 1/1000s). Pass nil to keep current.
    public func setManualExposure(iso: Float? = nil, shutterSpeed: Double? = nil) {
        guard let device = currentVideoDevice else { return }
        do {
            try device.lockForConfiguration()
            let targetISO = iso.map { max(device.activeFormat.minISO, min($0, device.activeFormat.maxISO)) }
                ?? device.iso
            let targetDuration: CMTime
            if let speed = shutterSpeed {
                targetDuration = CMTime(seconds: speed, preferredTimescale: 1_000_000)
            } else {
                targetDuration = device.exposureDuration
            }
            device.setExposureModeCustom(duration: targetDuration, iso: targetISO)
            device.unlockForConfiguration()
        } catch {
            print("CameraKit: Manual exposure error: \(error)")
        }
    }

    /// Set white balance temperature in Kelvin (e.g. 2700=warm, 5500=daylight, 7500=cool).
    public func setWhiteBalance(temperature: Float) {
        guard let device = currentVideoDevice else { return }
        do {
            try device.lockForConfiguration()
            let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: temperature, tint: 0
            )
            let gains = device.deviceWhiteBalanceGains(for: temperatureAndTint)
            let maxGain = device.maxWhiteBalanceGain
            let clampedGains = AVCaptureDevice.WhiteBalanceGains(
                redGain: max(1.0, min(gains.redGain, maxGain)),
                greenGain: max(1.0, min(gains.greenGain, maxGain)),
                blueGain: max(1.0, min(gains.blueGain, maxGain))
            )
            device.setWhiteBalanceModeLocked(with: clampedGains)
            device.unlockForConfiguration()
        } catch {
            print("CameraKit: White balance error: \(error)")
        }
    }

    /// Reset white balance to auto mode.
    public func setWhiteBalanceAuto() {
        guard let device = currentVideoDevice else { return }
        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            device.unlockForConfiguration()
        } catch {
            print("CameraKit: White balance auto error: \(error)")
        }
    }

    /// Pause current recording (iOS 9+).
    public func pauseRecording() {
        guard let movieOutput, isRecording else { return }
        movieOutput.pauseRecording()
    }

    /// Resume paused recording.
    public func resumeRecording() {
        guard let movieOutput, isRecording else { return }
        movieOutput.resumeRecording()
    }

    /// Get current device capabilities info.
    public func deviceInfo() -> [String: String] {
        guard let device = currentVideoDevice else { return ["status": "no device"] }
        var info: [String: String] = [
            "position": currentCameraPosition == .front ? "front" : "back",
            "zoom": String(format: "%.1f", currentZoom),
            "maxZoom": String(format: "%.1f", device.activeFormat.videoMaxZoomFactor),
            "minISO": String(format: "%.0f", device.activeFormat.minISO),
            "maxISO": String(format: "%.0f", device.activeFormat.maxISO),
            "hasTorch": device.hasTorch ? "yes" : "no",
            "lenses": availableLenses().map(\.rawValue).joined(separator: ", "),
            "isRecording": isRecording ? "yes" : "no",
        ]
        // Available framerates
        let maxFPS = device.activeFormat.videoSupportedFrameRateRanges
            .map { Int($0.maxFrameRate) }
            .max() ?? 30
        info["maxFPS"] = "\(maxFPS)"
        // Slow-mo support
        let slowMoFormats = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 }
        }
        info["slowMoSupported"] = slowMoFormats.isEmpty ? "no" : "yes"
        info["hasLiDAR"] = device.position == .back ? "check" : "no"
        return info
    }

    // MARK: - Slow Motion

    /// Available slow motion modes.
    public enum SlowMotionMode: String, Sendable {
        case normal    // 30fps
        case slo120    // 120fps
        case slo240    // 240fps
    }

    /// Set framerate for slow motion recording.
    public func setSlowMotion(_ mode: SlowMotionMode) {
        guard let device = currentVideoDevice else { return }

        let targetFPS: Double
        switch mode {
        case .normal: targetFPS = 30
        case .slo120: targetFPS = 120
        case .slo240: targetFPS = 240
        }

        // Find format that supports the target FPS
        let candidateFormats = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= targetFPS }
        }

        guard let format = candidateFormats.last else {
            print("CameraKit: \(mode.rawValue) not supported on this device")
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.unlockForConfiguration()
        } catch {
            print("CameraKit: Slow motion error: \(error)")
        }
    }

    // MARK: - Audio Level Monitoring

    @Published public var audioLevel: Float = 0

    /// Start monitoring audio levels. Updates `audioLevel` (0-1) in real-time.
    public func startAudioMonitoring() {
        guard audioEngine == nil else { return }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { let s = channelData[0][i]; sum += s * s }
            let rms = sqrt(sum / Float(max(frames, 1)))
            let db = 20 * log10(max(rms, 1e-10))
            let level = max(0, min(1, (db + 50) / 50))
            Task { @MainActor in self?.audioLevel = level }
        }
        do {
            try engine.start()
            audioEngine = engine
        } catch {
            print("CameraKit: Audio monitoring error: \(error)")
        }
    }

    /// Stop monitoring audio levels.
    public func stopAudioMonitoring() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioLevel = 0
    }

    /// Get current audio level description.
    public func audioLevelDescription() -> String {
        if audioLevel < 0.05 { return "silent" }
        if audioLevel < 0.2 { return "quiet" }
        if audioLevel < 0.5 { return "moderate" }
        if audioLevel < 0.8 { return "loud" }
        return "very loud"
    }

    public private(set) var audioEngine: AVAudioEngine?

    // MARK: - Photo Capture

    /// Capture a still photo from the current video frame.
    public func capturePhoto() async -> UIImage? {
        // Route through MultiCamService when PiP is active
        if let mcs = multiCamService, mcs.isRunning, let pixelBuffer = mcs.latestPixelBuffer {
            print("[CameraService] PiP active — capturing from MultiCamService composite frame")
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: cgImage)
        }
        return await withCheckedContinuation { continuation in
            pendingPhotoContinuation = continuation
        }
    }

    // MARK: - Frame Access

    /// Get the latest camera frame as a low-quality base64 JPEG string.
    /// Returns nil if no frame has been captured yet.
    public func getLatestFrameBase64(quality: CGFloat = 0.08) -> String? {
        guard let pixelBuffer = latestPixelBuffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: quality) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - Helpers

    private var currentVideoDevice: AVCaptureDevice? {
        session.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first { $0.hasMediaType(.video) }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()

        // Handle pending photo capture
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let image = context.createCGImage(ciImage, from: ciImage.extent).map { UIImage(cgImage: $0) }

        Task { @MainActor [weak self] in
            if let continuation = self?.pendingPhotoContinuation {
                self?.pendingPhotoContinuation = nil
                continuation.resume(returning: image)
            }
        }

        // Always store latest pixel buffer (copy for thread safety)
        var copiedBuffer: CVPixelBuffer?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &copiedBuffer)

        if let dst = copiedBuffer {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferLockBaseAddress(dst, [])
            if let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
               let dstBase = CVPixelBufferGetBaseAddress(dst) {
                memcpy(dstBase, srcBase, CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

            let sendable = SendablePixelBuffer(buffer: dst)
            Task { @MainActor [weak self] in
                self?.latestPixelBuffer = sendable.buffer
            }
        }

        // Throttled frame delivery for delegate
        guard now - lastFrameTime >= frameInterval else { return }
        lastFrameTime = now

        if let dst = copiedBuffer {
            let sendableBuffer = SendablePixelBuffer(buffer: dst)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.frameDelegate?.cameraService(self, didCaptureFrame: sendableBuffer)
            }
        }
    }
}

// MARK: - Recording Delegate

private final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    let completion: (URL?) -> Void

    init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        completion(error == nil ? outputFileURL : nil)
    }
}
#endif
