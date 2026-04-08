import SwiftUI
import CopilotSDK

// MARK: - Chat View

/// Full chat window: message list + tool activity + todo panel + input bar.
/// Works identically for both session and agent modes.
public struct ChatView: View {

    @ObservedObject private var viewModel: ChatViewModel
    private let inputModes: InputMode
    @State private var htmlPreviewURL: URL?

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

            if case .working = viewModel.chatState, viewModel.toolCalls.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            // Tool activity (if any tools are running)
            if !viewModel.toolCalls.isEmpty {
                ToolActivityView(toolCalls: viewModel.toolCalls)
                    .padding(.vertical, 4)
            }

            // Todo panel (above input bar, like VS Code chat)
            TodoPanelView(items: viewModel.todoItems)

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
            }

            Rectangle()
                .fill(platformGray5)
                .frame(height: 1)

            // Attachment chips (if any files are staged)
            if !viewModel.attachmentStore.entries.isEmpty {
                AttachmentChipBar(store: viewModel.attachmentStore)
            }

            // Input bar
            InputBar(
                viewModel: viewModel,
                inputModes: inputModes,
                onSend: { await viewModel.send() },
                onAttachment: { url in
                    viewModel.attachmentStore.add(url: url)
                    viewModel.objectWillChange.send()
                }
            )
        }
        .environment(\.openURL, OpenURLAction { url in
            // Intercept workspace file links (relative paths become file:// URLs)
            if url.pathExtension.lowercased() == "html" {
                // Try to resolve relative to workspace
                let resolved: URL
                if url.isFileURL {
                    resolved = url
                } else {
                    // Relative path — resolve against workspace
                    let workspaceURL = viewModel.workspaceURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    resolved = workspaceURL.appendingPathComponent(url.path)
                }
                if FileManager.default.fileExists(atPath: resolved.path) {
                    htmlPreviewURL = resolved
                    return .handled
                }
            }
            return .systemAction
        })
        .sheet(item: Binding(
            get: { htmlPreviewURL.map { IdentifiableURL(url: $0) } },
            set: { htmlPreviewURL = $0?.url }
        )) { item in
            HTMLPreviewView(fileURL: item.url)
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
                    ForEach(viewModel.filteredMessages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: viewModel.filteredMessages.count) { _, _ in
                if let lastId = viewModel.filteredMessages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
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


// MARK: - Identifiable URL Wrapper

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
