import SwiftUI
import CopilotSDK

// MARK: - Chat View

/// Full chat window: message list + tool activity + todo panel + input bar.
/// Works identically for both session and agent modes.
public struct ChatView: View {

    @ObservedObject private var viewModel: ChatViewModel
    private let inputModes: InputMode

    /// Create a chat view.
    /// - Parameters:
    ///   - viewModel: The chat view model (session or agent mode).
    ///   - inputModes: Which input modes to enable (default: text + speech).
    public init(viewModel: ChatViewModel, inputModes: InputMode = .textAndSpeech) {
        self.viewModel = viewModel
        self.inputModes = inputModes
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Connection status header
            if case .connecting = viewModel.chatState {
                connectionBanner
            }
            if case .error(let msg) = viewModel.chatState {
                errorBanner(msg)
            }

            // Message list
            messageList

            // Tool activity (if any tools are running)
            if !viewModel.toolCalls.isEmpty {
                ToolActivityView(toolCalls: viewModel.toolCalls)
                    .padding(.vertical, 4)
            }

            // Todo panel (above input bar, like VS Code chat)
            TodoPanelView(items: viewModel.todoItems)
                .padding(.bottom, 4)

            if case .waitingForQuestions(let questions) = viewModel.chatState {
                AskQuestionsView(
                    questions: questions,
                    onSubmit: { answers in
                        viewModel.submitAskQuestions(answers)
                    },
                    onSkip: {
                        viewModel.skipAskQuestions()
                    }
                )
                .padding(.bottom, 4)
            }

            // Input bar
            InputBar(
                viewModel: viewModel,
                inputModes: inputModes,
                onSend: { await viewModel.send() }
            )
        }
        .task {
            if viewModel.chatState == .disconnected {
                await viewModel.connect()
            }
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // Auto-scroll to bottom on new messages
                if let lastId = viewModel.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Status Banners

    private var connectionBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Connecting...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(platformGray6)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Retry") {
                Task { await viewModel.connect() }
            }
            .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
}

// MARK: - Public API Entry Point

/// Re-export key types for convenience.
/// Usage:
/// ```swift
/// import CopilotChat
/// let vm = ChatViewModel(transport: transport, mode: .agent(config))
/// ChatView(viewModel: vm, inputModes: [.text, .speech])
/// ```
public typealias CopilotChatView = ChatView
public typealias CopilotChatViewModel = ChatViewModel
