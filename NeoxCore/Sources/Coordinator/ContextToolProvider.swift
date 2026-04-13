import UIKit
import Network
import CopilotSDK

/// Provides a `get_context` tool for real-time device context.
public final class ContextToolProvider: @unchecked Sendable {
    private let workspaceURL: URL
    private let pathMonitor = NWPathMonitor()
    private var networkType: String = "unknown"
    private var isConnected: Bool = false

    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
        startNetworkMonitor()
    }

    deinit {
        pathMonitor.cancel()
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.isConnected = path.status == .satisfied
            if path.usesInterfaceType(.wifi) {
                self?.networkType = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                self?.networkType = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                self?.networkType = "ethernet"
            } else {
                self?.networkType = path.status == .satisfied ? "other" : "offline"
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    /// Current network status string for external use (e.g. environment_context section).
    public var currentNetworkStatus: String {
        "\(networkType), connected: \(isConnected)"
    }

    public var tools: [ToolDefinition] {
        [getContextTool]
    }

    private var getContextTool: ToolDefinition {
        ToolDefinition(
            name: "get_context",
            description: "Get current device context — time, battery, network, projects. Use to make context-aware decisions.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "include": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("time"), .string("battery"),
                                .string("network"), .string("projects")
                            ])
                        ]),
                        "description": .string("Which context signals to include. Defaults to all.")
                    ])
                ])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: ContextToolProvider unavailable" }

            var include: Set<String> = ["time", "battery", "network", "projects"]
            if case .object(let dict) = args, case .array(let items) = dict["include"] {
                include = Set(items.compactMap { if case .string(let s) = $0 { return s } else { return nil } })
            }

            var parts: [String] = []

            if include.contains("time") {
                parts.append(self.buildTimeContext())
            }
            if include.contains("battery") {
                parts.append(self.buildBatteryContext())
            }
            if include.contains("network") {
                parts.append(self.buildNetworkContext())
            }
            if include.contains("projects") {
                parts.append(self.buildProjectsContext())
            }

            return parts.joined(separator: "\n\n")
        }
    }

    private func buildTimeContext() -> String {
        let now = Date()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let weekdayFmt = DateFormatter()
        weekdayFmt.dateFormat = "EEEE"
        let timeOfDay: String
        switch hour {
        case 6..<10: timeOfDay = "morning"
        case 10..<14: timeOfDay = "midday"
        case 14..<18: timeOfDay = "afternoon"
        case 18..<22: timeOfDay = "evening"
        default: timeOfDay = "night"
        }
        return """
        time: \(fmt.string(from: now))
        dayOfWeek: \(weekdayFmt.string(from: now))
        timeOfDay: \(timeOfDay)
        timezone: \(TimeZone.current.identifier)
        """
    }

    @MainActor
    private func getBatteryInfo() -> (level: Float, state: UIDevice.BatteryState) {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        return (device.batteryLevel, device.batteryState)
    }

    private func buildBatteryContext() -> String {
        let info = DispatchQueue.main.sync { () -> (Float, String) in
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            let level = device.batteryLevel
            let state: String
            switch device.batteryState {
            case .charging: state = "charging"
            case .full: state = "full"
            case .unplugged: state = "unplugged"
            default: state = "unknown"
            }
            return (level, state)
        }
        let pct = info.0 >= 0 ? "\(Int(info.0 * 100))%" : "unknown"
        return "battery: \(pct) (\(info.1))"
    }

    private func buildNetworkContext() -> String {
        return "network: \(networkType), connected: \(isConnected)"
    }

    private func buildProjectsContext() -> String {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: workspaceURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return "projects: none" }

        let projects = contents.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return false }
            return fm.fileExists(atPath: url.appendingPathComponent("README.md").path)
        }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        if projects.isEmpty { return "projects: none" }

        var lines = ["projects:"]
        for proj in projects.prefix(20) {
            let name = proj.lastPathComponent
            var desc = ""
            if let readme = try? String(contentsOf: proj.appendingPathComponent("README.md"), encoding: .utf8) {
                if readme.hasPrefix("---") {
                    let parts = readme.components(separatedBy: "---")
                    if parts.count >= 3 {
                        let fmContent = parts[1]
                        for line in fmContent.components(separatedBy: "\n") {
                            if line.trimmingCharacters(in: .whitespaces).hasPrefix("description:") {
                                desc = line.replacingOccurrences(of: "description:", with: "").trimmingCharacters(in: .whitespaces)
                                break
                            }
                        }
                    }
                }
            }
            let modDate = (try? fm.attributesOfItem(atPath: proj.path)[.modificationDate] as? Date) ?? Date()
            let ago = Self.timeAgo(modDate)
            lines.append("- \(name)\(desc.isEmpty ? "" : ": \(desc)") (last modified: \(ago))")
        }
        return lines.joined(separator: "\n")
    }

    private static func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
