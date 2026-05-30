import SwiftUI
#if canImport(UIKit)
import UniformTypeIdentifiers
#endif

// MARK: - Input Bar

/// Multi-mode input bar: text field, speech button, attachment button, send button.
/// Adapts layout based on configured `InputMode` and current `ChatState`.
public struct InputBar: View {

    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var speechService = SpeechService()
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @FocusState private var isTextFieldFocused: Bool

    private let inputModes: InputMode
    private let onSend: () async -> Void
    private let onAttachment: ((URL) -> Void)?
    private let onAttachmentItemBegin: ((Bool) -> UUID)?
    private let onAttachmentItemEnd: ((UUID, URL?) -> Void)?

    public init(
        viewModel: ChatViewModel,
        inputModes: InputMode = .textAndSpeech,
        onSend: @escaping () async -> Void,
        onAttachment: ((URL) -> Void)? = nil,
        onAttachmentItemBegin: ((Bool) -> UUID)? = nil,
        onAttachmentItemEnd: ((UUID, URL?) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.inputModes = inputModes
        self.onSend = onSend
        self.onAttachment = onAttachment
        self.onAttachmentItemBegin = onAttachmentItemBegin
        self.onAttachmentItemEnd = onAttachmentItemEnd
    }

    public var body: some View {
        HStack(spacing: 8) {
            // Attachment button
            if inputModes.contains(.attachment) {
                attachmentButton
            }

            // Main input area
            if inputModes.contains(.text) {
                textField
            } else if inputModes.contains(.speech) {
                // Speech-only mode — large tap area
                speechOnlyButton
            }

            // Trailing buttons
            trailingButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .onAppear {
            if inputModes.contains(.speech) {
                speechService.requestAuthorization()
            }
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerSheet(
                onItemBegin: { isVideo in onAttachmentItemBegin?(isVideo) ?? UUID() },
                onItemEnd: { id, url in
                    if let url { onAttachment?(url) }
                    onAttachmentItemEnd?(id, url)
                }
            )
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: temp)
                try? FileManager.default.copyItem(at: url, to: temp)
                onAttachment?(temp)
            }
        }
        #endif
    }

    // MARK: - Subviews

    private var attachmentButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            Button {
                showFilePicker = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
        .disabled(!isInputEnabled)
    }

    private var textField: some View {
        HStack(spacing: 4) {
            TextField(placeholderText, text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isTextFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    isTextFieldFocused = false
                }
                .disabled(!isInputEnabled)

            if speechService.isListening {
                // Show pulsing indicator when listening
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .modifier(PulseAnimation())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(platformGray6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var speechOnlyButton: some View {
        Button {
            toggleSpeech()
        } label: {
            HStack {
                if speechService.isListening || speechService.isRecording {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                    Text(speechService.isRecording ? "Recording..." : "Listening...")
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.blue)
                    Text("Tap to speak")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(platformGray6)
            )
        }
        .disabled(!isInputEnabled)
    }

    @ViewBuilder
    private var trailingButtons: some View {
        if speechService.isListening || speechService.isRecording {
            // Stop listening/recording
            Button {
                if viewModel.useServerTranscription {
                    if let audioData = speechService.stopRecording() {
                        Task { await viewModel.sendAudio(audioData) }
                    }
                } else {
                    speechService.stopListening()
                }
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
            }
        } else if !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Send button
            Button {
                Task { await onSend() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
            }
        } else if inputModes.contains(.speech) && inputModes.contains(.text) {
            // Mic button (when text field is empty)
            Button {
                toggleSpeech()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .disabled(!isInputEnabled)
        } else {
            // Send button (always visible in text-only mode)
            Button {
                Task { await onSend() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(viewModel.inputText.isEmpty ? .gray : .blue)
            }
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Helpers

    private var placeholderText: String {
        switch viewModel.chatState {
        case .waitingForUser(let question):
            return question.prefix(50) + (question.count > 50 ? "..." : "")
        case .waitingForQuestions(let questions):
            guard let first = questions.first else { return "Answer questions..." }
            let question = first.question
            return question.prefix(50) + (question.count > 50 ? "..." : "")
        case .working:
            return "Steer..."
        case .connecting:
            return "Connecting..."
        default:
            return "Type a message..."
        }
    }

    private var borderColor: Color {
        switch viewModel.chatState {
        case .waitingForUser:
            return .orange
        case .waitingForQuestions:
            return .orange
        case .working:
            return .blue.opacity(0.5)
        default:
            return platformGray4
        }
    }

    private var isInputEnabled: Bool {
        switch viewModel.chatState {
        case .idle, .waitingForUser, .waitingForQuestions, .working:
            return true
        default:
            return false
        }
    }

    private func toggleSpeech() {
        if viewModel.useServerTranscription {
            // Server-side transcription mode: record audio → send to Mac
            if speechService.isRecording {
                if let audioData = speechService.stopRecording() {
                    Task { await viewModel.sendAudio(audioData) }
                }
            } else {
                do {
                    try speechService.startRecording()
                } catch {
                    // Recording failed — ignore silently
                }
            }
        } else if speechService.isListening {
            speechService.stopListening()
        } else {
            do {
                try speechService.startListening { text, isFinal in
                    Task { @MainActor in
                        viewModel.inputText = text
                        if isFinal {
                            Task { await onSend() }
                        }
                    }
                }
            } catch {
                // Speech failed — ignore silently
            }
        }
    }
}

// MARK: - Pulse Animation

private struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Photo Picker Sheet

#if canImport(UIKit)
import PhotosUI

/// Wrapper around PHPickerViewController for selecting photos and videos.
/// `onItemBegin(isVideo) -> UUID` fires synchronously per chosen item so the
/// receiver can show a per-chip spinner; `onItemEnd(id, url?)` fires when the
/// file is ready (url) or has failed (nil).
private struct PhotoPickerSheet: UIViewControllerRepresentable {
    let onItemBegin: @Sendable (Bool) -> UUID
    let onItemEnd: @Sendable (UUID, URL?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 10
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onItemBegin: onItemBegin, onItemEnd: onItemEnd)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onItemBegin: @Sendable (Bool) -> UUID
        let onItemEnd: @Sendable (UUID, URL?) -> Void

        init(onItemBegin: @escaping @Sendable (Bool) -> UUID,
             onItemEnd: @escaping @Sendable (UUID, URL?) -> Void) {
            self.onItemBegin = onItemBegin
            self.onItemEnd = onItemEnd
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }

            for result in results {
                let provider = result.itemProvider
                let isVideo = provider.hasRepresentationConforming(toTypeIdentifier: "public.movie")
                let type = isVideo ? "public.movie"
                    : (provider.hasRepresentationConforming(toTypeIdentifier: "public.image") ? "public.image" : nil)

                // Always register the placeholder synchronously on the main thread
                // so the chip-bar updates immediately.
                let id = onItemBegin(isVideo)

                guard let type else {
                    DispatchQueue.main.async { [onItemEnd] in onItemEnd(id, nil) }
                    continue
                }

                provider.loadFileRepresentation(forTypeIdentifier: type) { [onItemEnd] url, _ in
                    // The provided URL is only valid for the duration of this completion handler —
                    // copy it out synchronously before doing any async work.
                    var copied: URL?
                    if let url {
                        let unique = UUID().uuidString + "-" + url.lastPathComponent
                        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(unique)
                        do {
                            try FileManager.default.copyItem(at: url, to: temp)
                            copied = temp
                        } catch {
                            // copy failed — leave copied=nil
                        }
                    }
                    Task {
                        var staged: URL?
                        if let copied {
                            staged = await AttachmentImageProcessor.process(at: copied)
                        }
                        await MainActor.run { onItemEnd(id, staged) }
                    }
                }
            }
        }
    }
}
#endif
