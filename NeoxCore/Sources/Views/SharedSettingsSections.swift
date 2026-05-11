import SwiftUI
import CopilotSDK
import CopilotChat
import Feedback

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

            if !coordinator.supportsStoreKitTopUp {
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

    @AppStorage(NeoxCoreSettings.feedbackEndpointKey) private var feedbackEndpoint: String = NeoxCoreSettings.defaultFeedbackEndpoint
    @State private var showFeedbackSheet = false

    public init(coordinator: BaseCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Section("About") {
            if let url = URL(string: feedbackEndpoint), !feedbackEndpoint.isEmpty {
                Button("Send Feedback") {
                    showFeedbackSheet = true
                }
                .sheet(isPresented: $showFeedbackSheet) {
                    FeedbackView(
                        endpoint: url,
                        app: coordinator.appRuntimeConfig.appId,
                        appVersion: coordinator.appVersionString
                    )
                }
            }

            ForEach(coordinator.aboutLinks, id: \.self) { link in
                if let url = link.url {
                    Link(link.title, destination: url)
                }
            }

            LabeledContent("Version", value: coordinator.appVersionString)
        }
    }
}

/// Drop-in feedback section. Shows a "Send Feedback" button (manual UI) and
/// an opt-in toggle for auto-reporting uncaught crashes. Both flow through
/// the Feedback target which posts to a relay endpoint that hides the repo
/// + token from end users.
///
/// Wire-up:
///   1. Apps call `NeoxCoreFeedback.bootstrap(endpoint:app:appVersion:)` at
///      launch (typically in `AppDelegate` / `@main App.init`).
///   2. Add `SharedFeedbackSettingsSection(app:appVersion:)` to the settings
///      Form.
public struct SharedFeedbackSettingsSection: View {
    private let app: String
    private let appVersion: String?

    @AppStorage(NeoxCoreSettings.feedbackEndpointKey) private var endpointStr: String = NeoxCoreSettings.defaultFeedbackEndpoint
    @AppStorage(NeoxCoreSettings.feedbackAutoCrashReportKey) private var autoCrashReport: Bool = true
    @State private var showSheet = false

    public init(app: String, appVersion: String? = nil) {
        self.app = app
        self.appVersion = appVersion
    }

    public var body: some View {
        Section("Feedback") {
            if let url = URL(string: endpointStr), !endpointStr.isEmpty {
                Button {
                    showSheet = true
                } label: {
                    Label("Send Feedback", systemImage: "envelope")
                }
                .sheet(isPresented: $showSheet) {
                    FeedbackView(endpoint: url, app: app, appVersion: appVersion)
                }

                Toggle(isOn: $autoCrashReport) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto crash report")
                        Text("Send anonymized crash reports so the team can fix issues faster.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: autoCrashReport) { _, newValue in
                    NeoxCoreFeedback.setAutoCrashReportEnabled(newValue, app: app, appVersion: appVersion)
                }
            } else {
                // Endpoint not configured by the host app; render nothing
                // user-visible. Surface a developer-only hint in DEBUG.
                #if DEBUG
                Text("Feedback endpoint not configured. Call NeoxCoreFeedback.bootstrap(endpoint:app:appVersion:) at launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                EmptyView()
                #endif
            }
        }
    }
}

public struct SharedDeveloperSettingsSection<ExtraContent: View>: View {
    @ObservedObject private var coordinator: BaseCoordinator
    private let extraContent: () -> ExtraContent

    public init(
        coordinator: BaseCoordinator,
        @ViewBuilder extraContent: @escaping () -> ExtraContent
    ) {
        self.coordinator = coordinator
        self.extraContent = extraContent
    }

    public var body: some View {
        #if DEBUG
        Section("Chat") {
            Toggle("Show Usage", isOn: showUsageInChatBinding)
            Toggle("Show Progress", isOn: showProgressInChatBinding)
            Toggle("Show Build", isOn: showBuildInChatBinding)
        }

        Section("Developer") {
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
        }
        #endif
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
    init(coordinator: BaseCoordinator) {
        self.init(coordinator: coordinator) {
            EmptyView()
        }
    }
}
