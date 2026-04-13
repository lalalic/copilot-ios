import Foundation

/// Represents a discovered project in the workspace.
public struct ProjectItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let projectType: String?
    public let directoryURL: URL

    public init(id: String, name: String, description: String?, projectType: String?, directoryURL: URL) {
        self.id = id
        self.name = name
        self.description = description
        self.projectType = projectType
        self.directoryURL = directoryURL
    }
}

/// Discovers projects in the workspace by scanning for package.json files.
public enum ProjectDiscovery {
    /// Scan the workspace for directories containing package.json.
    public static func discoverProjects(in workspaceURL: URL) -> [ProjectItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url -> ProjectItem? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return nil }

            let packageURL = url.appendingPathComponent("package.json")
            guard let data = try? Data(contentsOf: packageURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let name = json["name"] as? String ?? url.lastPathComponent
            let description = json["description"] as? String
            let projectType = json["projectType"] as? String

            return ProjectItem(
                id: url.lastPathComponent,
                name: name,
                description: description,
                projectType: projectType,
                directoryURL: url
            )
        }.sorted(by: { $0.name < $1.name })
    }

    /// Read the projectType from a project's package.json.
    public static func readProjectType(projectId: String, workspaceURL: URL) -> String? {
        let packageURL = workspaceURL
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["projectType"] as? String else {
            return nil
        }
        return type
    }

    /// Load project context files (README.md, context.md, memory.md) for prompt injection.
    public static func loadProjectContext(projectId: String, workspaceURL: URL) -> String {
        let projectDir = workspaceURL.appendingPathComponent(projectId, isDirectory: true)
        var context = "You are a project assistant for '\(projectId)'.\n"

        let readmePath = projectDir.appendingPathComponent("README.md")
        let contextPath = projectDir.appendingPathComponent("context.md")
        let memoryPath = projectDir.appendingPathComponent("memory.md")

        if let readme = try? String(contentsOf: readmePath, encoding: .utf8), !readme.isEmpty {
            context += "\n## Project README\n\(readme)\n"
        }
        if let ctx = try? String(contentsOf: contextPath, encoding: .utf8), !ctx.isEmpty {
            context += "\n## Context\n\(ctx)\n"
        }
        if let memory = try? String(contentsOf: memoryPath, encoding: .utf8), !memory.isEmpty {
            context += "\n## Project Memory\n\(memory)\n"
        }

        return context
    }
}
