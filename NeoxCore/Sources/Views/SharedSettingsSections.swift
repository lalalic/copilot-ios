import SwiftUI
import CopilotChat

public struct SharedTopUpSettingsSection: View {
    @ObservedObject private var coordinator: BaseCoordinator
    @State private var showPayment = false

    public init(coordinator: BaseCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Section("Top Up") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Balance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "$%.2f", coordinator.usageTracker.balance))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(coordinator.usageTracker.balance < 1 ? .red : .primary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("This session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "$%.4f", coordinator.usageTracker.sessionCost))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if coordinator.supportsStoreKitTopUp {
                Button {
                    showPayment = true
                } label: {
                    Label("Top Up via App Store", systemImage: "creditcard")
                }
            }

            if coordinator.supportsStripeTopUp {
                Label("Stripe top-up available in chat", systemImage: "message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !coordinator.supportsStoreKitTopUp && !coordinator.supportsStripeTopUp {
                Text("No top-up options are configured for this app yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showPayment) {
            if let paymentManager = coordinator.paymentManager {
                PaymentView(paymentManager: paymentManager, usageTracker: coordinator.usageTracker)
            }
        }
    }
}

public struct SharedAboutSettingsSection: View {
    @ObservedObject private var coordinator: BaseCoordinator

    public init(coordinator: BaseCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Section("About") {
            ForEach(coordinator.aboutLinks, id: \.self) { link in
                if let url = link.url {
                    Link(destination: url) {
                        if let systemImage = link.systemImage, !systemImage.isEmpty {
                            Label(link.title, systemImage: systemImage)
                        } else {
                            Text(link.title)
                        }
                    }
                }
            }

            LabeledContent("Version", value: coordinator.appVersionString)
        }
    }
}

public struct SharedDeveloperSettingsSection<ExtraContent: View>: View {
    @ObservedObject private var coordinator: BaseCoordinator
    private let reconnectAction: (() -> Void)?
    private let extraContent: () -> ExtraContent

    public init(
        coordinator: BaseCoordinator,
        reconnectAction: (() -> Void)? = nil,
        @ViewBuilder extraContent: @escaping () -> ExtraContent
    ) {
        self.coordinator = coordinator
        self.reconnectAction = reconnectAction
        self.extraContent = extraContent
    }

    public var body: some View {
        #if DEBUG
        Section("Developer") {
            Toggle("Use local relay", isOn: useLocalRelayBinding)

            if coordinator.useLocalRelay {
                TextField("http://10.0.0.111:8765", text: localRelayURLBinding)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                TextField("Relay Host", text: relayHostBinding)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                HStack {
                    Text("Relay Port")
                    Spacer()
                    TextField("443", value: relayPortBinding, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .frame(width: 100)
                }
            }

            TextField("Model", text: selectedModelBinding)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Toggle("Text Input", isOn: enableTextInputBinding)
            Toggle("Speech Input", isOn: enableSpeechInputBinding)
            Toggle("Attachment Input", isOn: enableAttachmentInputBinding)

            Toggle("Show Usage in Chat", isOn: showUsageInChatBinding)
            Toggle("Show Progress in Chat", isOn: showProgressInChatBinding)
            Toggle("Show Build in Chat", isOn: showBuildInChatBinding)

            Toggle("Use Dev Server", isOn: useDevServerBinding)

            HStack {
                Text("Dev Server Port")
                Spacer()
                TextField("9223", value: devServerPortBinding, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .frame(width: 100)
                    .disabled(!coordinator.useDevServer)
            }

            extraContent()

            Button("Reconnect") {
                coordinator.saveSharedSettings()
                coordinator.saveRelaySettings()
                (reconnectAction ?? coordinator.reconnect)()
            }
        }
        #endif
    }

    private var useLocalRelayBinding: Binding<Bool> {
        Binding(
            get: { coordinator.useLocalRelay },
            set: { newValue in
                coordinator.useLocalRelay = newValue
                coordinator.applyRelaySelection()
                coordinator.saveRelaySettings()
            }
        )
    }

    private var localRelayURLBinding: Binding<String> {
        Binding(
            get: { coordinator.localRelayURL },
            set: { newValue in
                coordinator.localRelayURL = newValue
                coordinator.applyRelaySelection()
                coordinator.saveRelaySettings()
            }
        )
    }

    private var relayHostBinding: Binding<String> {
        Binding(
            get: { coordinator.relayHost },
            set: { newValue in
                coordinator.relayHost = newValue
                coordinator.saveRelaySettings()
            }
        )
    }

    private var relayPortBinding: Binding<Int> {
        Binding(
            get: { Int(coordinator.relayPort) },
            set: { newValue in
                coordinator.relayPort = UInt16(max(0, min(newValue, Int(UInt16.max))))
                coordinator.saveRelaySettings()
            }
        )
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { coordinator.selectedModel },
            set: { newValue in
                coordinator.selectedModel = newValue
                coordinator.saveSharedSettings()
            }
        )
    }

    private var enableTextInputBinding: Binding<Bool> {
        Binding(
            get: { coordinator.enableTextInput },
            set: { newValue in
                coordinator.enableTextInput = newValue
                coordinator.saveSharedSettings()
            }
        )
    }

    private var enableSpeechInputBinding: Binding<Bool> {
        Binding(
            get: { coordinator.enableSpeechInput },
            set: { newValue in
                coordinator.enableSpeechInput = newValue
                coordinator.saveSharedSettings()
            }
        )
    }

    private var enableAttachmentInputBinding: Binding<Bool> {
        Binding(
            get: { coordinator.enableAttachmentInput },
            set: { newValue in
                coordinator.enableAttachmentInput = newValue
                coordinator.saveSharedSettings()
            }
        )
    }

    private var showUsageInChatBinding: Binding<Bool> {
        Binding(
            get: { coordinator.showUsageInChat },
            set: { newValue in
                coordinator.showUsageInChat = newValue
                coordinator.saveSharedSettings()
            }
        )
    }

    private var showProgressInChatBinding: Binding<Bool> {
        Binding(
            get: { coordinator.showProgressInChat },
            set: { newValue in
                coordinator.showProgressInChat = newValue
                coordinator.saveSharedSettings()
            }
        )
    }

    private var showBuildInChatBinding: Binding<Bool> {
        Binding(
            get: { coordinator.showBuildInChat },
            set: { newValue in
                coordinator.showBuildInChat = newValue
                coordinator.saveSharedSettings()
            }
        )
    }

    private var useDevServerBinding: Binding<Bool> {
        Binding(
            get: { coordinator.useDevServer },
            set: { newValue in
                coordinator.useDevServer = newValue
                coordinator.saveSharedSettings()
            }
        )
    }

    private var devServerPortBinding: Binding<Int> {
        Binding(
            get: { coordinator.devServerPort },
            set: { newValue in
                coordinator.devServerPort = max(1, newValue)
                coordinator.saveSharedSettings()
            }
        )
    }
}

public extension SharedDeveloperSettingsSection where ExtraContent == EmptyView {
    init(coordinator: BaseCoordinator, reconnectAction: (() -> Void)? = nil) {
        self.init(coordinator: coordinator, reconnectAction: reconnectAction) {
            EmptyView()
        }
    }
}