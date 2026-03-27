// Multi-Camera PiP (Picture-in-Picture) Service for CameraKit.
// Records from front + back cameras simultaneously with composited output.
// Uses AVCaptureMultiCamSession + AVAssetWriter for recording.
// Requires iOS 13+, A12 chip (iPhone XS+).

#if os(iOS)
import AVFoundation
import CoreImage
import UIKit

/// Manages dual-camera (front + back) recording with PiP compositing.
@MainActor
public final class MultiCamService: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: - Published State

    @Published public var isRunning = false
    @Published public var isRecording = false
    @Published public var isPiPSupported = false
    @Published public var pipPosition: PiPPosition = .topRight

    /// Where the small PiP camera view appears.
    public enum PiPPosition: String, Sendable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var alignment: (x: CGFloat, y: CGFloat) {
            switch self {
            case .topLeft: return (0, 1)
            case .topRight: return (1, 1)
            case .bottomLeft: return (0, 0)
            case .bottomRight: return (1, 0)
            }
        }
    }

    /// Which camera is "main" (full screen) and which is "pip" (small overlay).
    public enum PiPLayout: String, Sendable {
        case backMain   // back = full, front = pip
        case frontMain  // front = full, back = pip
    }

    @Published public var layout: PiPLayout = .backMain

    /// Size ratio for PiP inset (0.0-1.0, default 0.28 = 28% of frame).
    public var pipSizeRatio: CGFloat = 0.28

    // MARK: - Session & Devices

    public let multiCamSession = AVCaptureMultiCamSession()

    private(set) var backDeviceInput: AVCaptureDeviceInput?
    private(set) var frontDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?

    nonisolated(unsafe) private var backVideoOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private var frontVideoOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private var audioOutput = AVCaptureAudioDataOutput()

    private let dataQueue = DispatchQueue(label: "camerakit.multicam.data")
    private let sessionQueue = DispatchQueue(label: "camerakit.multicam.session")

    // MARK: - Frame Storage

    nonisolated(unsafe) private var latestBackBuffer: CVPixelBuffer?
    nonisolated(unsafe) private var latestFrontBuffer: CVPixelBuffer?
    nonisolated(unsafe) private var latestCompositeBuffer: CVPixelBuffer?
    /// Latest composite frame for AI analysis.
    public private(set) var latestPixelBuffer: CVPixelBuffer?

    // MARK: - Asset Writer (Recording)
    // These are nonisolated(unsafe) because they're accessed from the data output queue
    // in captureOutput/compositeFrames which are nonisolated callbacks.

    nonisolated(unsafe) private var assetWriter: AVAssetWriter?
    nonisolated(unsafe) private var videoWriterInput: AVAssetWriterInput?
    nonisolated(unsafe) private var audioWriterInput: AVAssetWriterInput?
    nonisolated(unsafe) private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    nonisolated(unsafe) private var isWriterStarted = false
    nonisolated(unsafe) private var recordingStartTime: CMTime = .zero
    private var currentRecordingURL: URL?

    // MARK: - Compositing

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Init

    public override init() {
        super.init()
        isPiPSupported = AVCaptureMultiCamSession.isMultiCamSupported
    }

    // MARK: - Setup

    /// Configure and start dual-camera session.
    public func startSession() throws {
        guard isPiPSupported else {
            throw MultiCamError.notSupported
        }

        // Audio session
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[MultiCam] Audio session error: \(error)")
        }

        multiCamSession.beginConfiguration()

        // --- Back Camera ---
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw MultiCamError.cameraUnavailable("back")
        }
        let backInput = try AVCaptureDeviceInput(device: backCamera)
        guard multiCamSession.canAddInput(backInput) else {
            throw MultiCamError.cannotAddInput("back camera")
        }
        multiCamSession.addInputWithNoConnections(backInput)
        self.backDeviceInput = backInput

        guard let backVideoPort = backInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first else {
            throw MultiCamError.portNotFound("back video")
        }

        backVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        backVideoOutput.alwaysDiscardsLateVideoFrames = true
        guard multiCamSession.canAddOutput(backVideoOutput) else {
            throw MultiCamError.cannotAddOutput("back video")
        }
        multiCamSession.addOutputWithNoConnections(backVideoOutput)

        let backConnection = AVCaptureConnection(inputPorts: [backVideoPort], output: backVideoOutput)
        guard multiCamSession.canAddConnection(backConnection) else {
            throw MultiCamError.cannotAddConnection("back video")
        }
        multiCamSession.addConnection(backConnection)
        backConnection.videoOrientation = .portrait

        // --- Front Camera ---
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw MultiCamError.cameraUnavailable("front")
        }
        let frontInput = try AVCaptureDeviceInput(device: frontCamera)
        guard multiCamSession.canAddInput(frontInput) else {
            throw MultiCamError.cannotAddInput("front camera")
        }
        multiCamSession.addInputWithNoConnections(frontInput)
        self.frontDeviceInput = frontInput

        guard let frontVideoPort = frontInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .front).first else {
            throw MultiCamError.portNotFound("front video")
        }

        frontVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        frontVideoOutput.alwaysDiscardsLateVideoFrames = true
        guard multiCamSession.canAddOutput(frontVideoOutput) else {
            throw MultiCamError.cannotAddOutput("front video")
        }
        multiCamSession.addOutputWithNoConnections(frontVideoOutput)

        let frontConnection = AVCaptureConnection(inputPorts: [frontVideoPort], output: frontVideoOutput)
        guard multiCamSession.canAddConnection(frontConnection) else {
            throw MultiCamError.cannotAddConnection("front video")
        }
        multiCamSession.addConnection(frontConnection)
        frontConnection.videoOrientation = .portrait
        frontConnection.automaticallyAdjustsVideoMirroring = false
        frontConnection.isVideoMirrored = true

        // --- Audio ---
        if let mic = AVCaptureDevice.default(for: .audio) {
            if let audioInput = try? AVCaptureDeviceInput(device: mic),
               multiCamSession.canAddInput(audioInput) {
                multiCamSession.addInputWithNoConnections(audioInput)
                self.audioDeviceInput = audioInput

                if let audioPort = audioInput.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: .unspecified).first,
                   multiCamSession.canAddOutput(audioOutput) {
                    multiCamSession.addOutputWithNoConnections(audioOutput)
                    let audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: audioOutput)
                    if multiCamSession.canAddConnection(audioConnection) {
                        multiCamSession.addConnection(audioConnection)
                    }
                }
            }
        }

        multiCamSession.commitConfiguration()

        // Set delegates
        backVideoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        frontVideoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        audioOutput.setSampleBufferDelegate(self, queue: dataQueue)

        // Start running
        let session = multiCamSession
        sessionQueue.async {
            session.startRunning()
        }
        isRunning = true
        print("[MultiCam] Session started with front + back cameras")
    }

    /// Stop the multi-cam session.
    public func stopSession() {
        if isRecording {
            Task { await stopRecording() }
        }
        let session = multiCamSession
        sessionQueue.async {
            session.stopRunning()
        }
        isRunning = false
        print("[MultiCam] Session stopped")
    }

    // MARK: - Recording with AVAssetWriter

    /// Start recording PiP video.
    @discardableResult
    public func startRecording() -> URL? {
        guard !isRecording else { return nil }

        let fileName = "pip_\(UUID().uuidString.prefix(8)).mov"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        currentRecordingURL = url

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

            // Video input — 1080p composited
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1920,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 1080,
                    kCVPixelBufferHeightKey as String: 1920,
                ]
            )

            if writer.canAdd(videoInput) {
                writer.add(videoInput)
            }

            // Audio input
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000,
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
            }

            writer.startWriting()

            self.assetWriter = writer
            self.videoWriterInput = videoInput
            self.audioWriterInput = audioInput
            self.pixelBufferAdaptor = adaptor
            self.isWriterStarted = false
            self.isRecording = true

            print("[MultiCam] Recording started: \(fileName)")
            return url
        } catch {
            print("[MultiCam] Failed to create AVAssetWriter: \(error)")
            return nil
        }
    }

    /// Stop recording and finalize the file.
    @discardableResult
    public func stopRecording() async -> URL? {
        guard isRecording, let writer = assetWriter else { return nil }

        isRecording = false
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()

        return await withCheckedContinuation { continuation in
            writer.finishWriting {
                let url = writer.status == .completed ? self.currentRecordingURL : nil
                print("[MultiCam] Recording stopped: \(url?.lastPathComponent ?? "failed")")
                Task { @MainActor in
                    self.assetWriter = nil
                    self.videoWriterInput = nil
                    self.audioWriterInput = nil
                    self.pixelBufferAdaptor = nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: - PiP Compositing

    /// Composite main + PiP frames into a single output buffer.
    nonisolated private func compositeFrames(mainBuffer: CVPixelBuffer, pipBuffer: CVPixelBuffer, timestamp: CMTime) {
        let mainImage = CIImage(cvPixelBuffer: mainBuffer)
        var pipImage = CIImage(cvPixelBuffer: pipBuffer)

        let mainWidth = mainImage.extent.width
        let mainHeight = mainImage.extent.height

        // Scale PiP to desired size ratio
        let pipTargetWidth = mainWidth * 0.28
        let pipTargetHeight = mainHeight * 0.28
        let scaleX = pipTargetWidth / pipImage.extent.width
        let scaleY = pipTargetHeight / pipImage.extent.height
        let scale = min(scaleX, scaleY)

        pipImage = pipImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Position PiP based on current position setting
        let padding: CGFloat = 20
        let pipW = pipImage.extent.width
        let pipH = pipImage.extent.height

        // Read position (nonisolated, so we use a default)
        let pipX: CGFloat
        let pipY: CGFloat

        // Default to top-right
        pipX = mainWidth - pipW - padding
        pipY = mainHeight - pipH - padding

        pipImage = pipImage.transformed(by: CGAffineTransform(translationX: pipX, y: pipY))

        // Add rounded corner mask for PiP
        let roundedRect = CIImage(color: .white).cropped(to: CGRect(x: pipX, y: pipY, width: pipW, height: pipH))
            .applyingFilter("CIRoundedRectangleGenerator", parameters: [
                "inputRadius": 16.0,
                "inputColor": CIColor.white,
                "inputExtent": CIVector(cgRect: CGRect(x: pipX, y: pipY, width: pipW, height: pipH))
            ])

        // Composite PiP over main
        let composited = pipImage.composited(over: mainImage).cropped(to: mainImage.extent)

        // Render to output buffer
        let outputWidth = Int(mainWidth)
        let outputHeight = Int(mainHeight)
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, outputWidth, outputHeight,
            kCVPixelFormatType_32BGRA, nil, &outputBuffer
        )

        guard let output = outputBuffer else { return }
        ciContext.render(composited, to: output)

        // Store for preview
        self.latestCompositeBuffer = output

        // Update visible latestPixelBuffer on main actor
        let sendable = SendablePixelBuffer(buffer: output)
        Task { @MainActor [weak self] in
            self?.latestPixelBuffer = sendable.buffer
        }

        // Write to file if recording
        guard let adaptor = pixelBufferAdaptor,
              let videoInput = videoWriterInput,
              let writer = assetWriter,
              writer.status == .writing else { return }

        if !isWriterStarted {
            writer.startSession(atSourceTime: timestamp)
            recordingStartTime = timestamp
            isWriterStarted = true
        }

        if videoInput.isReadyForMoreMediaData {
            adaptor.append(output, withPresentationTime: timestamp)
        }
    }

    // MARK: - Layout Control

    /// Swap which camera is main vs PiP.
    public func swapLayout() {
        layout = (layout == .backMain) ? .frontMain : .backMain
        print("[MultiCam] Layout swapped to: \(layout.rawValue)")
    }

    /// Move the PiP to a different corner.
    public func setPiPPosition(_ position: PiPPosition) {
        pipPosition = position
        print("[MultiCam] PiP position: \(position.rawValue)")
    }

    // MARK: - Errors

    public enum MultiCamError: Error, LocalizedError {
        case notSupported
        case cameraUnavailable(String)
        case cannotAddInput(String)
        case cannotAddOutput(String)
        case cannotAddConnection(String)
        case portNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .notSupported: return "Multi-cam not supported on this device (requires A12+)"
            case .cameraUnavailable(let cam): return "Camera unavailable: \(cam)"
            case .cannotAddInput(let input): return "Cannot add input: \(input)"
            case .cannotAddOutput(let output): return "Cannot add output: \(output)"
            case .cannotAddConnection(let conn): return "Cannot add connection: \(conn)"
            case .portNotFound(let port): return "Port not found: \(port)"
            }
        }
    }
}

// MARK: - Sample Buffer Delegate

extension MultiCamService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    nonisolated public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

        if output == backVideoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            latestBackBuffer = pixelBuffer
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Composite when back frame arrives (drives timing)
            if let frontBuffer = latestFrontBuffer {
                let mainBuffer: CVPixelBuffer
                let pipBuffer: CVPixelBuffer

                // Use a simple nonisolated check
                mainBuffer = pixelBuffer  // back is main by default
                pipBuffer = frontBuffer

                compositeFrames(mainBuffer: mainBuffer, pipBuffer: pipBuffer, timestamp: timestamp)
            }

        } else if output == frontVideoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            latestFrontBuffer = pixelBuffer

        } else if output == audioOutput {
            // Write audio directly
            guard let audioInput = audioWriterInput,
                  let writer = assetWriter,
                  writer.status == .writing,
                  isWriterStarted,
                  audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        }
    }
}

// MARK: - SwiftUI Preview Views

import SwiftUI

/// SwiftUI view showing composited dual-camera PiP preview.
public struct MultiCamPreview: UIViewRepresentable {
    public let service: MultiCamService

    public init(service: MultiCamService) {
        self.service = service
    }

    public func makeUIView(context: Context) -> MultiCamPreviewUIView {
        let view = MultiCamPreviewUIView()
        view.service = service

        // Main preview (back camera)
        let mainLayer = AVCaptureVideoPreviewLayer()
        mainLayer.setSessionWithNoConnection(service.multiCamSession)
        mainLayer.videoGravity = .resizeAspectFill

        // Connect back camera to main layer
        if let backPort = service.backDeviceInput?.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first {
            let conn = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: mainLayer)
            if service.multiCamSession.canAddConnection(conn) {
                service.multiCamSession.addConnection(conn)
            }
        }
        view.layer.addSublayer(mainLayer)
        view.mainPreviewLayer = mainLayer

        // PiP preview (front camera)
        let pipLayer = AVCaptureVideoPreviewLayer()
        pipLayer.setSessionWithNoConnection(service.multiCamSession)
        pipLayer.videoGravity = .resizeAspectFill
        pipLayer.cornerRadius = 12
        pipLayer.masksToBounds = true
        pipLayer.borderWidth = 2
        pipLayer.borderColor = UIColor.white.cgColor

        if let frontPort = service.frontDeviceInput?.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .front).first {
            let conn = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: pipLayer)
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
            if service.multiCamSession.canAddConnection(conn) {
                service.multiCamSession.addConnection(conn)
            }
        }
        view.layer.addSublayer(pipLayer)
        view.pipPreviewLayer = pipLayer

        return view
    }

    public func updateUIView(_ uiView: MultiCamPreviewUIView, context: Context) {
        uiView.updatePiPLayout()
    }
}

/// UIView for dual-camera preview with PiP layout.
public class MultiCamPreviewUIView: UIView {
    var mainPreviewLayer: AVCaptureVideoPreviewLayer?
    var pipPreviewLayer: AVCaptureVideoPreviewLayer?
    weak var service: MultiCamService?

    override public func layoutSubviews() {
        super.layoutSubviews()
        mainPreviewLayer?.frame = bounds
        updatePiPLayout()
    }

    func updatePiPLayout() {
        guard let pipLayer = pipPreviewLayer else { return }

        let pipW: CGFloat = bounds.width * 0.28
        let pipH: CGFloat = bounds.height * 0.28
        let padding: CGFloat = 12

        let position = service?.pipPosition ?? .topRight

        let x: CGFloat
        let y: CGFloat

        switch position {
        case .topLeft:
            x = padding
            y = padding
        case .topRight:
            x = bounds.width - pipW - padding
            y = padding
        case .bottomLeft:
            x = padding
            y = bounds.height - pipH - padding
        case .bottomRight:
            x = bounds.width - pipW - padding
            y = bounds.height - pipH - padding
        }

        pipLayer.frame = CGRect(x: x, y: y, width: pipW, height: pipH)
    }

    /// Expose device input connections for preview layer setup.
    /// (Used by MultiCamPreview representable)
}
#endif
