#if os(iOS)
import Foundation
import AVFoundation
import Speech
import os

private let voiceLog = Logger(subsystem: "com.copilot.camerakit", category: "voice")

/// Wrapper for TTS synthesis result to satisfy Sendable.
private struct TTSResult: @unchecked Sendable {
    let format: AVAudioFormat
    let buffers: [AVAudioPCMBuffer]
}

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

    /// Synthesize text to a WAV audio file. Returns the file URL.
    public func synthesizeToFile(_ text: String, outputURL: URL, language: String = "en-US", rate: Float = 0.95, pitch: Float = 1.05) async throws -> URL {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        utterance.pitchMultiplier = pitch
        utterance.voice = AVSpeechSynthesisVoice(language: language)

        let wrapper = await withCheckedContinuation { (continuation: CheckedContinuation<TTSResult, Never>) in
            nonisolated(unsafe) var capturedFormat: AVAudioFormat?
            nonisolated(unsafe) var buffers: [AVAudioPCMBuffer] = []
            nonisolated(unsafe) var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                    if capturedFormat == nil { capturedFormat = pcm.format }
                    buffers.append(pcm.copy() as! AVAudioPCMBuffer)
                } else if !buffers.isEmpty, let fmt = capturedFormat {
                    finished = true
                    continuation.resume(returning: TTSResult(format: fmt, buffers: buffers))
                }
            }
        }

        let audioFile = try AVAudioFile(forWriting: outputURL, settings: wrapper.format.settings)
        for pcm in wrapper.buffers {
            try audioFile.write(from: pcm)
        }

        voiceLog.info("Synthesized TTS to \(outputURL.lastPathComponent), \(audioFile.length) frames")
        return outputURL
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
        NSLog("[VoiceService] startListening() called")
        voiceLog.info("startListening() called")
        transcribedText = ""

        guard AVAudioApplication.shared.recordPermission == .granted else {
            NSLog("[VoiceService] Record permission not granted, requesting...")
            voiceLog.warning("Record permission not granted, requesting...")
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor [weak self] in
                    if granted { self?.startListening() }
                }
            }
            return
        }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            NSLog("[VoiceService] Speech recognition not authorized, requesting...")
            voiceLog.warning("Speech recognition not authorized, requesting...")
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor [weak self] in
                    if status == .authorized { self?.startListening() }
                }
            }
            return
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            voiceLog.error("Speech recognizer unavailable")
            return
        }

        voiceLog.info("Setting audio session category .playAndRecord")
        // Audio session already configured by camera — skip reconfiguration to avoid conflicts
        NSLog("[VoiceService] Audio session state: category=%@, mode=%@", AVAudioSession.sharedInstance().category.rawValue, AVAudioSession.sharedInstance().mode.rawValue)

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
            NSLog("[VoiceService] Audio engine started, listening...")
            voiceLog.info("Audio engine started, listening...")
        } catch {
            NSLog("[VoiceService] Audio engine error: %@", String(describing: error))
            voiceLog.error("Audio engine error: \(error)")
        }
    }

    /// Stop listening.
    public func stopListening() {
        voiceLog.info("stopListening() called")
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
        NSLog("[VoiceService] listen(duration: %.1f) called", duration)
        voiceLog.info("listen(duration: \(duration)) called")
        startListening()
        NSLog("[VoiceService] listen: sleeping for %.1f s", duration)
        voiceLog.info("listen: sleeping for \(duration)s")
        try? await Task.sleep(for: .seconds(duration))
        let text = transcribedText
        NSLog("[VoiceService] listen: woke up, text=%@", String(text.prefix(80)))
        voiceLog.info("listen: woke up, text=\(text.prefix(80))")
        stopListening()
        NSLog("[VoiceService] listen: returning %d chars", text.count)
        voiceLog.info("listen: returning \(text.count) chars")
        return text
    }
}
#endif
