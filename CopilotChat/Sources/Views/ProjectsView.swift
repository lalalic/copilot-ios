import SwiftUI

// MARK: - Project Model

/// A workspace project — a top-level directory with metadata.
public struct Project: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let url: URL
    public let fileCount: Int
    public let modifiedDate: Date?
    public let repo: String?

    public init(name: String, url: URL, fileCount: Int = 0, modifiedDate: Date? = nil, repo: String? = nil) {
        self.id = name
        self.name = name
        self.url = url
        self.fileCount = fileCount
        self.modifiedDate = modifiedDate
        self.repo = repo
    }
}

// MARK: - Projects View

/// Popover/sheet displaying workspace projects with select action.
public struct ProjectsView: View {
    let rootURL: URL
    let currentProject: String?
    let onSelect: (Project?) -> Void
    let onDelete: ((Project) -> Void)?

    @State private var projects: [Project] = []
    @State private var projectToDelete: Project?
    @Environment(\.dismiss) private var dismiss

    public init(rootURL: URL, currentProject: String? = nil, onSelect: @escaping (Project?) -> Void, onDelete: ((Project) -> Void)? = nil) {
        self.rootURL = rootURL
        self.currentProject = currentProject
        self.onSelect = onSelect
        self.onDelete = onDelete
    }

    public var body: some View {
        NavigationStack {
            List {
                // "All" option — no project scoping
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.stack.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        Text("All Projects")
                            .font(.body)
                        Spacer()
                        if currentProject == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }

                Section("Projects") {
                    ForEach(projects) { project in
                        Button {
                            onSelect(project)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .foregroundStyle(.indigo)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .font(.body)
                                    if project.fileCount > 0 {
                                        Text("\(project.fileCount) items")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if currentProject == project.name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                projectToDelete = project
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { loadProjects() }
            .alert("Delete Project?", isPresented: Binding(
                get: { projectToDelete != nil },
                set: { if !$0 { projectToDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) { projectToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let project = projectToDelete {
                        deleteProject(project)
                    }
                }
            } message: {
                if let project = projectToDelete {
                    Text("This will permanently delete \"\(project.name)\" and all its files.")
                }
            }
        }
    }

    private func loadProjects() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else { return }

        let hiddenPrefixes: Set<String> = [".github", ".neo", ".git", ".tmp"]

        projects = entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.first != "." || !hiddenPrefixes.contains(name) else { return nil }
            guard name.first != "." else { return nil }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { return nil }

            // Count items inside
            let children = (try? fm.contentsOfDirectory(atPath: url.path))?.count ?? 0
            let modified = values?.contentModificationDate

            // Read repo from package.json if present
            let pkgURL = url.appendingPathComponent("package.json")
            var repo: String? = nil
            if let data = try? Data(contentsOf: pkgURL),
               let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                repo = pkg["repo"] as? String
            }

            return Project(name: name, url: url, fileCount: children, modifiedDate: modified, repo: repo)
        }
        .sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
    }

    private func deleteProject(_ project: Project) {
        try? FileManager.default.removeItem(at: project.url)
        projects.removeAll { $0.id == project.id }
        if currentProject == project.name {
            onSelect(nil)
        }
        onDelete?(project)
    }
}

// MARK: - Project Badge (nav bar button)

/// A compact nav-bar button showing the current project name or an icon.
public struct ProjectBadgeView: View {
    let currentProject: String?
    let action: () -> Void

    public init(currentProject: String?, action: @escaping () -> Void) {
        self.currentProject = currentProject
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.caption)
                if let name = currentProject {
                    Text(name)
                        .font(.caption.bold())
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                currentProject != nil
                    ? Color.indigo.opacity(0.15)
                    : Color.clear
            )
            .clipShape(Capsule())
        }
    }
}
