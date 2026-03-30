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

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    public init(locale: Locale = .current) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Request speech recognition authorization.
    public func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.isAuthorized = (status == .authorized)
            }
        }
    }

    /// Start listening and transcribing speech.
    /// - Parameter onResult: Called with each partial/final transcription result.
    public func startListening(onResult: @escaping @Sendable (String, Bool) -> Void) throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        // Cancel any ongoing task
        stopListening()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { @MainActor in
                    self.transcript = text
                    onResult(text, isFinal)
                    if isFinal {
                        self.stopListening()
                    }
                }
            }

            if error != nil {
                Task { @MainActor in
                    self.stopListening()
                }
            }
        }

        isListening = true
    }

    /// Stop listening and clean up audio resources.
    public func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
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
