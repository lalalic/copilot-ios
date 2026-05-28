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

    public init(
        viewModel: ChatViewModel,
        inputModes: InputMode = .textAndSpeech,
        onSend: @escaping () async -> Void,
        onAttachment: ((URL) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.inputModes = inputModes
        self.onSend = onSend
        self.onAttachment = onAttachment
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
            PhotoPickerSheet { url in
                onAttachment?(url)
            } onDismiss: {
                showPhotoPicker = false
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: temp)
                    try? FileManager.default.copyItem(at: url, to: temp)
                    let shrunk = AttachmentImageProcessor.shrinkIfImage(at: temp) ?? temp
                    onAttachment?(shrunk)
                }
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

/// Wrapper around PHPickerViewController for selecting photos.
private struct PhotoPickerSheet: UIViewControllerRepresentable {
    let onSelect: (URL) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0 // unlimited
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onDismiss: onDismiss)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelect: (URL) -> Void
        let onDismiss: () -> Void

        init(onSelect: @escaping (URL) -> Void, onDismiss: @escaping () -> Void) {
            self.onSelect = onSelect
            self.onDismiss = onDismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            defer { onDismiss() }
            for result in results {
                let provider = result.itemProvider
                let types = ["public.image", "public.movie"]
                for type in types where provider.hasRepresentationConforming(toTypeIdentifier: type) {
                    provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
                        guard let self, let url else { return }
                        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                        try? FileManager.default.removeItem(at: temp)
                        try? FileManager.default.copyItem(at: url, to: temp)
                        let shrunk = AttachmentImageProcessor.shrinkIfImage(at: temp) ?? temp
                        DispatchQueue.main.async {
                            self.onSelect(shrunk)
                        }
                    }
                    break
                }
            }
        }
    }
}
#endif
