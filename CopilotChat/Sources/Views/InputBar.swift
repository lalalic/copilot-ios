import SwiftUI

// MARK: - Input Bar

/// Multi-mode input bar: text field, speech button, attachment button, send button.
/// Adapts layout based on configured `InputMode` and current `ChatState`.
public struct InputBar: View {

    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var speechService = SpeechService()
    @State private var showAttachmentPicker = false

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
        .sheet(isPresented: $showAttachmentPicker) {
            AttachmentPicker { url in
                onAttachment?(url)
                showAttachmentPicker = false
            }
        }
    }

    // MARK: - Subviews

    private var attachmentButton: some View {
        Button {
            showAttachmentPicker = true
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
                if speechService.isListening {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                    Text("Listening...")
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
        if speechService.isListening {
            // Stop listening
            Button {
                speechService.stopListening()
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
        if speechService.isListening {
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
