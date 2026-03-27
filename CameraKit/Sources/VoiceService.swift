#if os(iOS)
import Foundation
import AVFoundation
import Speech

// MARK: - Voice Output (TTS)

/// Text-to-speech service.
public final class VoiceOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published public var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var speakContinuation: CheckedContinuation<Void, Never>?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak text via TTS. Non-blocking — returns immediately.
    public func speak(_ text: String, rate: Float = 0.95, pitch: Float = 1.05) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        utterance.pitchMultiplier = pitch
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    /// Speak text and wait until finished.
    public func speakAndWait(_ text: String, rate: Float = 0.95, pitch: Float = 1.05) async {
        speak(text, rate: rate, pitch: pitch)
        await withCheckedContinuation { continuation in
            speakContinuation = continuation
        }
    }

    /// Stop speaking immediately.
    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speakContinuation?.resume()
        speakContinuation = nil
    }

    // MARK: - Delegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        speakContinuation?.resume()
        speakContinuation = nil
    }
}

// MARK: - Voice Input (Speech Recognition)

/// Speech recognition service — listens and returns transcribed text.
@MainActor
public final class VoiceInput: ObservableObject {
    @Published public var isListening = false
    @Published public var transcribedText = ""
    @Published public var soundLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    public init() {}

    /// Request microphone and speech recognition permissions.
    nonisolated public func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioApplication.requestRecordPermission { _ in }
    }

    /// Start listening. Updates `transcribedText` in real-time.
    public func startListening() {
        transcribedText = ""

        guard AVAudioApplication.shared.recordPermission == .granted else {
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor [weak self] in
                    if granted { self?.startListening() }
                }
            }
            return
        }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor [weak self] in
                    if status == .authorized { self?.startListening() }
                }
            }
            return
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("CameraKit: Audio session error: \(error)")
            return
        }

        do {
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            let inputNode = engine.inputNode
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                request.append(buffer)
                guard let channelData = buffer.floatChannelData else { return }
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames { let s = channelData[0][i]; sum += s * s }
                let rms = sqrt(sum / Float(max(frames, 1)))
                let db = 20 * log10(max(rms, 1e-10))
                let level = max(0, min(1, (db + 50) / 50))
                Task { @MainActor in self?.soundLevel = level }
            }

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    Task { @MainActor in
                        self.transcribedText = result.bestTranscription.formattedString
                    }
                }
                if error != nil || (result?.isFinal ?? false) {
                    Task { @MainActor in self.stopListening() }
                }
            }

            try engine.start()
            audioEngine = engine
            recognitionRequest = request
            isListening = true
        } catch {
            print("CameraKit: Audio engine error: \(error)")
        }
    }

    /// Stop listening.
    public func stopListening() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        soundLevel = 0
    }

    /// Listen for a given duration and return the transcribed text.
    public func listen(duration: TimeInterval = 5.0) async -> String {
        startListening()
        try? await Task.sleep(for: .seconds(duration))
        let text = transcribedText
        stopListening()
        return text
    }
}
#endif
