import Foundation
import Speech
import AVFoundation

// MARK: - Speech Service

/// Handles speech-to-text using SFSpeechRecognizer.
/// Streams partial transcription results for real-time display.
@MainActor
public final class SpeechService: ObservableObject {

    @Published public var isListening: Bool = false
    @Published public var transcript: String = ""
    @Published public var isAuthorized: Bool = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Lazily create AVAudioEngine to avoid crash on init before audio session is configured.
    private lazy var audioEngine = AVAudioEngine()
    private var isAudioTapInstalled = false
    private let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Request speech recognition authorization.
    public func requestAuthorization() {
        // Lazily create the recognizer on first use
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: locale)
        }
        // Use nonisolated static helper to break @MainActor isolation chain.
        // SFSpeechRecognizer.requestAuthorization calls its handler on a background queue,
        // but closures in @MainActor classes inherit that isolation, causing a runtime crash.
        SpeechService.performAuthRequest { [weak self] authorized in
            Task { @MainActor in
                self?.isAuthorized = authorized
            }
        }
    }

    /// Nonisolated helper — closures defined here do NOT inherit @MainActor.
    private nonisolated static func performAuthRequest(handler: @escaping @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            handler(status == .authorized)
        }
    }

    /// Start listening and transcribing speech.
    /// - Parameter onResult: Called with each partial/final transcription result.
    public func startListening(onResult: @escaping @Sendable (String, Bool) -> Void) throws {
        guard isAuthorized else {
            throw SpeechError.notAuthorized
        }

        // Lazily create recognizer
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: locale)
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        // Cancel any ongoing task
        if isListening {
            stopListening()
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        if isAudioTapInstalled {
            inputNode.removeTap(onBus: 0)
            isAudioTapInstalled = false
        }
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        SpeechService.installAudioTap(
            inputNode: inputNode,
            request: request,
            format: recordingFormat
        )
        isAudioTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()

        // Use nonisolated static helper to break @MainActor isolation chain.
        // The recognitionTask handler runs on a background queue.
        recognitionTask = SpeechService.startRecognitionTask(
            recognizer: speechRecognizer,
            request: request
        ) { [weak self] text, isFinal in
            Task { @MainActor in
                self?.transcript = text
                onResult(text, isFinal)
                if isFinal {
                    self?.stopListening()
                }
            }
        } onError: { [weak self] in
            Task { @MainActor in
                self?.stopListening()
            }
        }

        isListening = true
    }

    /// Nonisolated helper — closures defined here do NOT inherit @MainActor.
    private nonisolated static func startRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onResult: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable () -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                onResult(text, isFinal)
            }
            if error != nil {
                onError()
            }
        }
    }

    /// Nonisolated helper for installing the audio tap.
    /// The tap closure runs on a realtime audio queue and must not inherit @MainActor isolation.
    private nonisolated static func installAudioTap(
        inputNode: AVAudioInputNode,
        request: SFSpeechAudioBufferRecognitionRequest,
        format: AVAudioFormat
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    /// Stop listening and clean up audio resources.
    public func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isAudioTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isAudioTapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isListening = false
    }

    /// Toggle listening on/off. Returns the final transcript when stopping.
    public func toggleListening(onResult: @escaping @Sendable (String, Bool) -> Void) throws {
        if isListening {
            stopListening()
        } else {
            try startListening(onResult: onResult)
        }
    }
}

// MARK: - Errors

public enum SpeechError: Error, LocalizedError {
    case recognizerUnavailable
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "Speech recognizer is not available"
        case .notAuthorized: return "Speech recognition not authorized"
        }
    }
}
