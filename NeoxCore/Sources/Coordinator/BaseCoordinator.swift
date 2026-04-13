import Foundation
import UIKit
import CopilotSDK
import CopilotChat
import WebKitAgent
import Network
#if canImport(MediaKit)
import MediaKit
#endif

/// Base coordinator providing generic app infrastructure.
/// Apps subclass this to add their own channels, project types, and UI.
///
/// Provides: relay connection, session management, tool registration,
/// settings persistence, project sessions, workspace bootstrapping.
@MainActor
open class BaseCoordinator: ObservableObject {
    public let connectionManager = ConnectionManager()
    @Published public var currentSession: String? = nil
    public var isConnected: Bool {
        guard let state = chatViewModel?.chatState else { return false }
        return state != .disconnected && state != .connecting
    }
    @Published public var registeredTools: [RegisteredTool] = []
    @Published public var isAgentRunning: Bool = false

    // MARK: - Relay Settings

    @Published public var useLocalRelay: Bool = UserDefaults.standard.object(forKey: NeoxCoreSettings.useLocalRelayKey) == nil ? false : UserDefaults.standard.bool(forKey: NeoxCoreSettings.useLocalRelayKey)
    @Published public var localRelayURL: String = UserDefaults.standard.string(forKey: NeoxCoreSettings.localRelayURLKey) ?? NeoxCoreSettings.defaultLocalRelayURL
    @Published public var relayHost: String = UserDefaults.standard.string(forKey: NeoxCoreSettings.relayHostKey) ?? NeoxCoreSettings.defaultRelayHost
    @Published public var relayPort: UInt16 = UInt16(UserDefaults.standard.integer(forKey: NeoxCoreSettings.relayPortKey)) == 0 ? NeoxCoreSettings.defaultRelayPort : UInt16(UserDefaults.standard.integer(forKey: NeoxCoreSettings.relayPortKey))

    // MARK: - Dev Server Settings

    @Published public var useDevServer: Bool = UserDefaults.standard.object(forKey: NeoxCoreSettings.useDevServerKey) == nil ? true : UserDefaults.standard.bool(forKey: NeoxCoreSettings.useDevServerKey)
    @Published public var devServerPort: Int = {
        let saved = UserDefaults.standard.integer(forKey: NeoxCoreSettings.devServerPortKey)
        return saved == 0 ? NeoxCoreSettings.defaultDevServerPort : saved
    }()

    // MARK: - Chat Input Modes

    @Published public var enableTextInput: Bool = UserDefaults.standard.object(forKey: NeoxCoreSettings.enableTextInputKey) == nil ? true : UserDefaults.standard.bool(forKey: NeoxCoreSettings.enableTextInputKey)
    @Published public var enableSpeechInput: Bool = UserDefaults.standard.object(forKey: NeoxCoreSettings.enableSpeechInputKey) == nil ? true : UserDefaults.standard.bool(forKey: NeoxCoreSettings.enableSpeechInputKey)
    @Published public var enableAttachmentInput: Bool = UserDefaults.standard.object(forKey: NeoxCoreSettings.enableAttachmentInputKey) == nil ? true : UserDefaults.standard.bool(forKey: NeoxCoreSettings.enableAttachmentInputKey)

    // MARK: - Notification Visibility

    @Published public var showUsageInChat: Bool = UserDefaults.standard.object(forKey: NeoxCoreSettings.showUsageInChatKey) == nil ? false : UserDefaults.standard.bool(forKey: NeoxCoreSettings.showUsageInChatKey)
    @Published public var showProgressInChat: Bool = UserDefaults.standard.object(forKey: NeoxCoreSettings.showProgressInChatKey) == nil ? true : UserDefaults.standard.bool(forKey: NeoxCoreSettings.showProgressInChatKey)
    @Published public var showBuildInChat: Bool = UserDefaults.standard.object(forKey: NeoxCoreSettings.showBuildInChatKey) == nil ? true : UserDefaults.standard.bool(forKey: NeoxCoreSettings.showBuildInChatKey)

    // MARK: - Identity

    @Published public var neoxUserId: String = {
        if let saved = UserDefaults.standard.string(forKey: NeoxCoreSettings.userIdKey), !saved.isEmpty {
            return saved
        }
        let id = UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(String(id), forKey: NeoxCoreSettings.userIdKey)
        return String(id)
    }()

    @Published public var selectedModel: String = UserDefaults.standard.string(forKey: NeoxCoreSettings.selectedModelKey) ?? NeoxCoreSettings.defaultModel

    // MARK: - Tool Providers

    private var webToolProvider: WebAgentToolProvider?
    public let workspaceBootstrapper: WorkspaceBootstrapper
    public let workspaceURL: URL
    public let fileToolProvider: FileToolProvider
    public let memoryToolProvider: MemoryToolProvider
    public var memoryTools: MemoryToolProvider { memoryToolProvider }
    public var fileTools: FileToolProvider { fileToolProvider }
    public let subAgentToolProvider: SubAgentToolProvider
    public let contextToolProvider: ContextToolProvider
    public let terminalToolProvider: TerminalToolProvider
    public let scriptToolProvider: ScriptToolProvider
    public let downloadToolProvider: DownloadToolProvider
    #if canImport(MediaKit)
    public let ffmpegToolProvider: FFmpegToolProvider
    #endif

    // MARK: - Agent

    public let agentProfile: AgentRuntimeProfile?
    private let profileLoader: AgentProfileLoader
    private var agent: CopilotAgent?
    private var agentTask: Task<Void, Never>?
    @Published public private(set) var chatViewModel: ChatViewModel?
    @Published public private(set) var paymentManager: PaymentManager?

    // MARK: - Project Sessions

    public private(set) var projectSessions: [String: ChatViewModel] = [:]
    public var projectResponseHandlers: [String: @Sendable (String) async -> Void] = [:]
    public var activeWatcherCount: Int { projectSessions.count }

    /// App identifier for relay session appId (e.g., "neox", "intento").
    open var appId: String { "neox-core" }

    // MARK: - Init

    public init() {
        let bootstrapper = WorkspaceBootstrapper()
        let loader = AgentProfileLoader()
        let resolvedWorkspace: URL
        if let bootstrapped = try? bootstrapper.ensureWorkspaceReady() {
            resolvedWorkspace = bootstrapped
        } else {
            let appSupport = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            resolvedWorkspace = appSupport.appendingPathComponent("workspace", isDirectory: true)
            try? FileManager.default.createDirectory(at: resolvedWorkspace, withIntermediateDirectories: true)
        }

        self.workspaceBootstrapper = bootstrapper
        self.profileLoader = loader
        self.workspaceURL = resolvedWorkspace
        self.fileToolProvider = FileToolProvider(baseDirectory: resolvedWorkspace)
        self.memoryToolProvider = MemoryToolProvider(baseDirectory: resolvedWorkspace)
        let memProvider = self.memoryToolProvider
        let fileProvider = self.fileToolProvider
        let savedPort = UserDefaults.standard.integer(forKey: NeoxCoreSettings.relayPortKey)
        let savedHost = UserDefaults.standard.string(forKey: NeoxCoreSettings.relayHostKey) ?? NeoxCoreSettings.defaultRelayHost
        let resolvedPort: UInt16 = savedPort > 0 ? UInt16(savedPort) : NeoxCoreSettings.defaultRelayPort
        let terminalProvider = TerminalToolProvider(workspaceURL: resolvedWorkspace)
        self.terminalToolProvider = terminalProvider
        self.subAgentToolProvider = SubAgentToolProvider(
            workspaceURL: resolvedWorkspace,
            relayHost: savedHost,
            relayPort: resolvedPort,
            userId: UserDefaults.standard.string(forKey: NeoxCoreSettings.userIdKey),
            toolsBuilder: {
                var tools: [CopilotSDK.ToolDefinition] = []
                tools.append(contentsOf: fileProvider.tools)
                tools.append(contentsOf: memProvider.tools)
                tools.append(contentsOf: terminalProvider.tools)
                return tools
            }
        )
        self.contextToolProvider = ContextToolProvider(workspaceURL: resolvedWorkspace)
        self.scriptToolProvider = ScriptToolProvider(workspaceURL: resolvedWorkspace, terminalProvider: terminalProvider)
        self.downloadToolProvider = DownloadToolProvider(baseDirectory: resolvedWorkspace)
        #if canImport(MediaKit)
        self.ffmpegToolProvider = FFmpegToolProvider(baseDirectory: resolvedWorkspace)
        #endif
        self.agentProfile = try? loader.load(from: resolvedWorkspace)

        applyRelaySelection()
        registerDefaultTools()
    }

    // MARK: - Tool Registration

    /// All tools including dynamically registered ones.
    public var allRegisteredTools: [RegisteredTool] {
        var tools = registeredTools
        if webToolProvider != nil {
            tools.append(RegisteredTool(name: "web-agent", description: "Browser automation CLI (via run_in_terminal)"))
            tools.append(RegisteredTool(name: "site", description: "Site adapter CLI (via run_in_terminal)"))
        }
        return tools
    }

    public func registerDefaultTools() {
        registeredTools = [
            RegisteredTool(name: "speak", description: "Read text aloud to user"),
            RegisteredTool(name: "listen", description: "Listen for voice input"),
            RegisteredTool(name: "notify", description: "Send local notification"),
            RegisteredTool(name: "take_photo", description: "Capture photo with camera"),
            RegisteredTool(name: "copy_to_clipboard", description: "Copy text to clipboard"),
            RegisteredTool(name: "memory_read", description: "Read memory notes under .neo"),
            RegisteredTool(name: "memory_append", description: "Append timestamped memory notes"),
            RegisteredTool(name: "memory_write_section", description: "Write/replace memory markdown sections"),
            RegisteredTool(name: "memory_log_session", description: "Create session notes in .neo/reports/sessions"),
            RegisteredTool(name: "memory_list", description: "List memory files under .neo"),
            RegisteredTool(name: "create_project", description: "Scaffold a new project from .templates/projects/"),
            RegisteredTool(name: "run_in_terminal", description: "Execute shell commands on device (ls, grep, curl, etc.)"),
            RegisteredTool(name: "run_script", description: "Execute JavaScript code on device (loops, JSON, data processing)"),
            RegisteredTool(name: "start_coding_task", description: "Start coding task: create GitHub repo, issue, assign coding agent"),
            RegisteredTool(name: "send_response", description: "Send a response message to the user"),
            RegisteredTool(name: "create_plan", description: "Create a scheduled plan from chat"),
            RegisteredTool(name: "stripe_checkout", description: "Generate external Stripe checkout link when requested"),
            RegisteredTool(name: "run_sub_agent", description: "Run a named sub-agent in a separate session"),
            RegisteredTool(name: "get_context", description: "Get device context: time, battery, network, projects"),
            RegisteredTool(name: "memory_search", description: "Search across memory files by keyword"),
            RegisteredTool(name: "memory_delete", description: "Delete a memory file or section"),
            RegisteredTool(name: "memory_get_yesterday", description: "Get yesterday's daily summary"),
        ]
        #if canImport(MediaKit)
        registeredTools.append(contentsOf: [
            RegisteredTool(name: "ffmpeg", description: "Run ffmpeg media processing commands"),
            RegisteredTool(name: "ffprobe", description: "Inspect media metadata and streams"),
        ])
        #endif
    }

    // MARK: - WebKit Agent

    public func setupWebKitAgent(manager: WebViewManager) {
        webToolProvider = WebAgentToolProvider(manager: manager)

        if let webProvider = webToolProvider {
            terminalToolProvider.registerCommand(name: "web-agent") { [weak webProvider] command in
                guard let provider = webProvider else { return "Error: web-agent not available" }
                return try await provider.handleCLI(command)
            }

            terminalToolProvider.registerCommand(name: "site") { [weak webProvider] command in
                guard let provider = webProvider else { return "Error: site adapters not available" }
                let args = command.drop(while: { !$0.isWhitespace }).drop(while: { $0.isWhitespace })
                return try await provider.handleSiteCLI(String(args))
            }

            chatViewModel?.fileConverter = { @Sendable [weak webProvider] filePath, format in
                guard let provider = webProvider else {
                    throw NSError(domain: "BaseCoordinator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Web agent not available"])
                }
                return try await provider.convertFile(filePath: filePath, outputFormat: format)
            }
        }
    }

    // MARK: - Workspace Paths

    public var mainAgentFileURL: URL {
        workspaceURL
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("main.agent.md")
    }

    public var workspaceRootURL: URL { workspaceURL }

    // MARK: - Notifications

    public func shouldShowNotificationInChat(type: String) -> Bool {
        switch type {
        case "usage": return showUsageInChat
        case "agent_progress": return showProgressInChat
        case "build_complete", "build_failed": return showBuildInChat
        default: return true
        }
    }

    // MARK: - Build Tools

    public func buildTools() -> [CopilotSDK.ToolDefinition] {
        var tools: [CopilotSDK.ToolDefinition] = []
        tools.append(contentsOf: fileToolProvider.tools)
        tools.append(contentsOf: memoryToolProvider.tools)
        tools.append(contentsOf: subAgentToolProvider.tools)
        tools.append(contentsOf: contextToolProvider.tools)
        tools.append(contentsOf: terminalToolProvider.tools)
        tools.append(contentsOf: scriptToolProvider.tools)
        tools.append(contentsOf: downloadToolProvider.tools)
        #if canImport(MediaKit)
        tools.append(contentsOf: ffmpegToolProvider.tools)
        #endif
        return tools
    }

    /// Override point: apps can add their own tools to the set.
    open func additionalTools() -> [CopilotSDK.ToolDefinition] { [] }

    // MARK: - Device Context

    public func buildDeviceContext() -> String {
        let device = UIDevice.current
        let screen = UIScreen.main
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let timeOfDay: String
        switch hour {
        case 6..<10: timeOfDay = "morning"
        case 10..<14: timeOfDay = "midday"
        case 14..<18: timeOfDay = "afternoon"
        case 18..<22: timeOfDay = "evening"
        default: timeOfDay = "night"
        }
        let weekdayFmt = DateFormatter()
        weekdayFmt.dateFormat = "EEEE"

        device.isBatteryMonitoringEnabled = true
        let batteryLevel = device.batteryLevel >= 0 ? "\(Int(device.batteryLevel * 100))%" : "unknown"
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        default: batteryState = "unknown"
        }

        let preferredLang = Locale.preferredLanguages.first ?? "en"
        let regionCode = Locale.current.region?.identifier ?? "unknown"

        let storage: String
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeBytes = attrs[.systemFreeSize] as? Int64,
           let totalBytes = attrs[.systemSize] as? Int64 {
            let freeGB = Double(freeBytes) / 1_073_741_824
            let totalGB = Double(totalBytes) / 1_073_741_824
            storage = String(format: "%.1fGB free / %.0fGB total", freeGB, totalGB)
        } else {
            storage = "unknown"
        }

        let network = contextToolProvider.currentNetworkStatus

        return """
        * Device: \(device.model) (\(device.name))
        * OS: \(device.systemName) \(device.systemVersion)
        * Screen: \(Int(screen.bounds.width))x\(Int(screen.bounds.height))pt @\(Int(screen.scale))x
        * Storage: \(storage)
        * Battery: \(batteryLevel) (\(batteryState))
        * Network: \(network)
        * Language: \(preferredLang), Region: \(regionCode)
        * Time: \(fmt.string(from: now))
        * Day: \(weekdayFmt.string(from: now)), \(timeOfDay)
        * Timezone: \(TimeZone.current.identifier)
        """
    }

    public func buildWorkspaceTree() -> String {
        let fm = FileManager.default
        let excludes: Set<String> = ["node_modules", ".git", "build", "build-sim", "build-device", ".build"]

        func listDir(_ url: URL, prefix: String, depth: Int) -> String {
            guard depth > 0 else { return "" }
            guard let contents = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter({ !excludes.contains($0.lastPathComponent) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return "" }

            let dotContents = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
            ).filter({ $0.lastPathComponent.hasPrefix(".") && !excludes.contains($0.lastPathComponent) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })) ?? []

            let allItems = (dotContents + contents).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            var seen = Set<String>()
            let unique = allItems.filter { seen.insert($0.lastPathComponent).inserted }

            var result = ""
            for item in unique {
                let name = item.lastPathComponent
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                result += "\(prefix)\(name)\(isDir ? "/" : "")\n"
                if isDir {
                    result += listDir(item, prefix: prefix + "  ", depth: depth - 1)
                }
            }
            return result
        }

        return listDir(workspaceURL, prefix: "", depth: 3)
    }

    public func buildTemplateInfo() -> String {
        let fm = FileManager.default
        let templatesDir = workspaceURL
            .appendingPathComponent(".templates", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)

        guard let templates = try? fm.contentsOfDirectory(
            at: templatesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter({
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            return ""
        }

        var lines: [String] = ["## project templates", "Read the template's README.md before creating a new project.", ""]
        lines.append("| Template | Description |")
        lines.append("|----------|-------------|")

        for template in templates {
            let name = template.lastPathComponent
            let readmeURL = template.appendingPathComponent("README.md")
            var description = ""
            if let content = try? String(contentsOf: readmeURL, encoding: .utf8) {
                let readmeLines = content.components(separatedBy: "\n")
                for (i, line) in readmeLines.enumerated() {
                    if line.lowercased().hasPrefix("# goal") && i + 1 < readmeLines.count {
                        description = readmeLines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
            if description.isEmpty { description = name }
            lines.append("| `\(name)` | \(description) |")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Chat Input Modes

    public var chatInputModes: InputMode {
        var modes: InputMode = []
        if enableTextInput { modes.insert(.text) }
        if enableSpeechInput { modes.insert(.speech) }
        if enableAttachmentInput { modes.insert(.attachment) }
        return modes.isEmpty ? .textAndSpeech : modes
    }

    // MARK: - Chat ViewModel

    /// Create the shared CopilotChat view model configured for agent mode.
    /// Subclasses can override `configureChat(vm:)` to do additional wiring (e.g., Discord).
    public func createChatViewModel() -> ChatViewModel {
        normalizeInputSettings()
        var tools = buildTools()
        tools.append(contentsOf: additionalTools())
        var instructions = agentProfile?.preambleBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let tree = buildWorkspaceTree()
        if !tree.isEmpty {
            instructions += "\n\n## current workspace files\n```\n\(tree)```"
        }
        let templateInfo = buildTemplateInfo()
        if !templateInfo.isEmpty {
            instructions += "\n\n\(templateInfo)"
        }
        if let skills = agentProfile?.skills,
           let skillSection = SkillDiscovery.buildPromptSection(from: skills) {
            instructions += "\n\n\(skillSection)"
        }
        var sections = agentProfile?.sections ?? [:]
        sections["environment_context"] = .replace(content: buildDeviceContext())
        let mobileTone = "You are on a mobile device with a small screen. Keep responses concise — 1-3 sentences for simple answers. Use bullet points for lists. Avoid unnecessary introductions, conclusions, and filler. Do not repeat the user's question back."
        if let existing = sections["tone"] {
            if case .replace(content: let content) = existing {
                sections["tone"] = .replace(content: content + "\n" + mobileTone)
            } else {
                sections["tone"] = .append(content: mobileTone)
            }
        } else {
            sections["tone"] = .append(content: mobileTone)
        }
        let finalSections: [String: SystemMessageSectionAction]? = sections.isEmpty ? nil : sections
        let model = selectedModel

        let transport = WebSocketTransport(host: relayHost, port: relayPort)

        let vm = ChatViewModel(
            transport: transport,
            mode: .agent(AgentConfig(
                model: model,
                instructions: instructions,
                sections: finalSections,
                tools: tools,
                appId: appId,
                deviceToken: UserDefaults.standard.string(forKey: "apnsDeviceToken"),
                apnsEnv: {
                    #if DEBUG
                    return "sandbox"
                    #else
                    return "production"
                    #endif
                }(),
                userId: neoxUserId,
                onResponse: { _ in },
                onAskUser: { _ in "" }
            )),
            inputModes: chatInputModes,
            workspaceURL: workspaceURL,
            notificationFilter: { [weak self] type in
                guard let self else { return true }
                switch type {
                case "usage": return self.showUsageInChat
                case "agent_progress": return self.showProgressInChat
                case "build_complete", "build_failed": return self.showBuildInChat
                default: return true
                }
            }
        )

        self.chatViewModel = vm
        self.paymentManager = PaymentManager(usageTracker: vm.usageTracker)

        // Allow subclasses to do additional wiring (e.g., Discord)
        configureChat(vm: vm)

        Task { await vm.connect() }
        return vm
    }

    /// Override point: called after ChatViewModel is created, before connect.
    /// Use to wire channels (Discord, WeChat, etc.)
    open func configureChat(vm: ChatViewModel) {}

    // MARK: - Reconnect

    open func reconnect() {
        applyRelaySelection()
        saveRelaySettings()
        chatViewModel?.disconnect()
        chatViewModel = nil
        _ = createChatViewModel()
    }

    public func stopAgent() {
        chatViewModel?.disconnect()
        isAgentRunning = false
    }

    // MARK: - Project Sessions

    /// Create a dedicated agent session for a project.
    /// Override `configureProjectSession` for app-specific wiring (e.g., guardrails).
    public func createProjectSession(projectId: String, onResponse: @escaping @Sendable (String) async -> Void) -> ChatViewModel {
        projectResponseHandlers[projectId] = onResponse
        if let existing = projectSessions[projectId] { return existing }

        let transport = WebSocketTransport(host: relayHost, port: relayPort)

        var projectContext = ProjectDiscovery.loadProjectContext(projectId: projectId, workspaceURL: workspaceURL)
        projectContext += "\nYou are a project assistant. Be helpful and concise.\n"
        projectContext += "\nKeep responses under 3 sentences unless the question requires a detailed answer. Match the language of the sender."
        projectContext += "\nUse memory tools with path '\(projectId)/memory.md' to remember project-specific info (contacts, preferences, key facts). Read it at session start."
        projectContext += "\nThis is a channel-connected session. Messages come from Discord or WeChat users. Use ask_questions when you need clarification."

        // Allow subclasses to customize instructions and tools
        let (extraInstructions, extraTools) = projectSessionCustomization(projectId: projectId)
        projectContext += extraInstructions

        var tools = buildTools()
        tools.append(contentsOf: extraTools)

        let model = selectedModel
        let appIdStr = appId

        let vm = ChatViewModel(
            transport: transport,
            mode: .agent(AgentConfig(
                model: model,
                instructions: projectContext,
                tools: tools,
                appId: "\(appIdStr)-\(projectId)",
                deviceToken: UserDefaults.standard.string(forKey: "apnsDeviceToken"),
                apnsEnv: {
                    #if DEBUG
                    return "sandbox"
                    #else
                    return "production"
                    #endif
                }(),
                userId: neoxUserId,
                onResponse: { [weak self] response in
                    let handler = await MainActor.run { self?.projectResponseHandlers[projectId] }
                    await handler?(response)
                },
                onAskUser: { _ in "" }
            )),
            workspaceURL: workspaceURL
        )

        projectSessions[projectId] = vm
        vm.skipPendingRestore = true
        Task { await vm.connect() }
        NSLog("[BaseCoordinator] Created project session for '%@' (appId: %@-%@)", projectId, appIdStr, projectId)
        return vm
    }

    /// Override point: return additional instructions and tools for project sessions.
    open func projectSessionCustomization(projectId: String) -> (instructions: String, tools: [CopilotSDK.ToolDefinition]) {
        return ("", [])
    }

    public func destroyProjectSession(projectId: String) {
        guard let vm = projectSessions.removeValue(forKey: projectId) else { return }
        projectResponseHandlers.removeValue(forKey: projectId)
        vm.disconnect()
        print("[BaseCoordinator] Destroyed project session for '\(projectId)'")
    }

    /// Read the projectType from a project's package.json.
    public func readProjectType(projectId: String) -> String? {
        ProjectDiscovery.readProjectType(projectId: projectId, workspaceURL: workspaceURL)
    }

    // MARK: - Sub-Agent

    public func runSubAgent(name: String, task: String, model: String? = nil) async -> String {
        return await subAgentToolProvider.runAgent(name: name, task: task, model: model)
    }

    // MARK: - Settings

    public func normalizeInputSettings() {
        if !enableTextInput && !enableSpeechInput && !enableAttachmentInput {
            enableTextInput = true
        }
    }

    public func applyRelaySelection() {
        if useLocalRelay {
            if let parsed = NeoxCoreSettings.parseRelayURL(localRelayURL) {
                relayHost = parsed.host
                relayPort = parsed.port
            } else {
                relayHost = "10.0.0.111"
                relayPort = 8765
                localRelayURL = "http://10.0.0.111:8765"
            }
        } else {
            relayHost = NeoxCoreSettings.defaultRelayHost
            relayPort = NeoxCoreSettings.defaultRelayPort
        }
    }

    open func saveRelaySettings() {
        NeoxCoreSettings.saveRelaySettings(
            useLocalRelay: useLocalRelay,
            localRelayURL: localRelayURL,
            relayHost: relayHost,
            relayPort: relayPort
        )
    }

    public func parseLocalRelayURL() -> (host: String, port: UInt16) {
        NeoxCoreSettings.parseRelayURL(localRelayURL) ?? ("10.0.0.111", 8765)
    }
}
