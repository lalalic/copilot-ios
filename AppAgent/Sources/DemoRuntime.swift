#if os(iOS)
import Foundation
import UIKit
import AVFoundation
import Combine

/// Manages visual demo overlay state. DemoToolProvider mutates this; DemoOverlayView observes it.
@MainActor
public final class DemoRuntime: ObservableObject {
    // MARK: - Published State

    @Published public var isActive = false
    @Published public var isPaused = false

    @Published public var spotlightFrame: CGRect?
    @Published public var tooltipText: String?
    @Published public var tooltipPosition: CGPoint?
    @Published public var captionText: String?
    @Published public var stepNumber: Int = 0
    @Published public var stepTitle: String?
    @Published public var cursorPosition: CGPoint?
    @Published public var cursorVisible = false

    // MARK: - Recording

    public private(set) var events: [DemoEvent] = []
    private var recordingStart: Date?

    // MARK: - Dependencies

    private let scanner: AccessibilityScanner
    private let synthesizer = AVSpeechSynthesizer()

    public init(scanner: AccessibilityScanner) {
        self.scanner = scanner
    }

    // MARK: - Element Resolution

    public func frameForRef(_ ref: String) -> CGRect? {
        scanner.elements.first { $0.ref == ref }?.frame
    }

    public func frameForLabel(_ label: String) -> CGRect? {
        let needle = label.lowercased()
        return scanner.elements.first { $0.label.lowercased().contains(needle) }?.frame
    }

    /// Resolve ref or label to a CGRect; returns nil if neither matches.
    func resolveFrame(ref: String?, label: String?) -> CGRect? {
        if let ref, let frame = frameForRef(ref) { return frame }
        if let label, let frame = frameForLabel(label) { return frame }
        return nil
    }

    // MARK: - Actions

    public func step(_ title: String) {
        guard !isPaused else { return }
        stepNumber += 1
        stepTitle = title
        isActive = true
        record(type: "step", text: title)
    }

    public func spotlight(ref: String?, label: String?, text: String?) {
        guard !isPaused else { return }
        guard let frame = resolveFrame(ref: ref, label: label) else { return }
        spotlightFrame = frame
        if let text {
            tooltipText = text
            tooltipPosition = CGPoint(x: frame.midX, y: frame.maxY + 8)
        }
        isActive = true
        record(type: "spotlight", text: text, target: ref ?? label)
    }

    public func annotate(ref: String?, label: String?, text: String) {
        guard !isPaused else { return }
        guard let frame = resolveFrame(ref: ref, label: label) else { return }
        tooltipText = text
        tooltipPosition = CGPoint(x: frame.midX, y: frame.maxY + 8)
        isActive = true
        record(type: "annotate", text: text, target: ref ?? label)
    }

    public func caption(_ text: String) {
        guard !isPaused else { return }
        captionText = text
        isActive = true
        record(type: "caption", text: text)
    }

    public func hideCaption() {
        captionText = nil
    }

    public func say(_ text: String) async {
        guard !isPaused else { return }
        captionText = text
        isActive = true
        record(type: "say", text: text)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let delegate = SpeechDelegate { cont.resume() }
            // Prevent delegate from being deallocated
            objc_setAssociatedObject(self.synthesizer, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            self.synthesizer.delegate = delegate
            self.synthesizer.speak(utterance)
        }

        captionText = nil
    }

    public func cursorTo(ref: String?, label: String?) async {
        guard !isPaused else { return }
        guard let frame = resolveFrame(ref: ref, label: label) else { return }
        let target = CGPoint(x: frame.midX, y: frame.midY)
        cursorVisible = true
        cursorPosition = target
        isActive = true
        record(type: "cursor", target: ref ?? label)

        // Brief pause for animation to land
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    public func highlight(ref: String?, label: String?) {
        guard !isPaused else { return }
        guard let frame = resolveFrame(ref: ref, label: label) else { return }
        // Briefly show spotlight without dimming (just the green pulse)
        spotlightFrame = frame
        isActive = true
        record(type: "highlight", target: ref ?? label)

        // Auto-clear after 0.6s
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if self.spotlightFrame == frame {
                self.spotlightFrame = nil
            }
        }
    }

    public func clear() {
        spotlightFrame = nil
        tooltipText = nil
        tooltipPosition = nil
        captionText = nil
        stepTitle = nil
        stepNumber = 0
        cursorVisible = false
        cursorPosition = nil
        isActive = false
        record(type: "clear")
    }

    public func pause() {
        isPaused = true
        record(type: "pause")
    }

    public func resume() {
        isPaused = false
        record(type: "resume")
    }

    public func startRecording() {
        events.removeAll()
        recordingStart = Date()
        record(type: "recording_start")
    }

    public func stopRecording() -> [DemoEvent] {
        record(type: "recording_stop")
        recordingStart = nil
        return events
    }

    // MARK: - Event Recording

    private func record(type: String, text: String? = nil, target: String? = nil, duration: TimeInterval? = nil) {
        guard recordingStart != nil else { return }
        let ts = Date().timeIntervalSince(recordingStart!) * 1000
        events.append(DemoEvent(timestamp: ts, type: type, text: text, target: target, duration: duration))
    }
}

// MARK: - DemoEvent

public struct DemoEvent: Codable, Sendable {
    public let timestamp: TimeInterval
    public let type: String
    public let text: String?
    public let target: String?
    public let duration: TimeInterval?
}

// MARK: - Speech Delegate

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish()
    }
}
#endif
