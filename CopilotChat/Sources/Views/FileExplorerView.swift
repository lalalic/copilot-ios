import SwiftUI
import CopilotSDK

// MARK: - File Explorer View

/// A reusable file explorer that browses the on-device workspace directory.
/// Shows folder tree with icons, supports navigation and file preview.
public struct FileExplorerView: View {

    private let rootURL: URL
    private let title: String
    @State private var currentPath: URL
    @State private var entries: [FileEntry] = []
    @State private var selectedFile: FileEntry?
    @State private var fileContent: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pathStack: [URL] = []

    /// Create a file explorer rooted at the given directory.
    /// - Parameters:
    ///   - rootURL: The root directory to browse. Browsing is confined to this directory.
    ///   - title: Navigation title (default: "Files").
    public init(rootURL: URL, title: String = "Files") {
        self.rootURL = rootURL
        self.title = title
        self._currentPath = State(initialValue: rootURL)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Breadcrumb bar
                breadcrumbBar

                Divider()

                // File list or file preview
                if let content = fileContent, let file = selectedFile {
                    filePreviewView(file: file, content: content)
                } else {
                    fileListView
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear { loadEntries() }
        }
    }

    // MARK: - Breadcrumb Bar

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Root
                Button {
                    navigateTo(rootURL)
                } label: {
                    Label("Root", systemImage: "folder.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }

                // Path components from root to current
                let rootStd = rootURL.standardizedFileURL.path
                let currStd = currentPath.standardizedFileURL.path
                let relativePath = currStd.replacingOccurrences(of: rootStd, with: "")
                let components = relativePath.split(separator: "/").map(String.init)
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        let subPath = components[0...index].joined(separator: "/")
                        let url = rootURL.appendingPathComponent(subPath)
                        navigateTo(url)
                    } label: {
                        Text(component)
                            .font(.caption)
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(platformGray6.opacity(0.5))
    }

    // MARK: - File List

    private var fileListView: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Empty folder")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        fileRow(entry)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func fileRow(_ entry: FileEntry) -> some View {
        Button {
            if entry.isDirectory {
                navigateTo(entry.url)
            } else {
                openFile(entry)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .foregroundColor(entry.iconColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if !entry.isDirectory, let size = entry.formattedSize {
                        Text(size)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - File Preview

    private func filePreviewView(file: FileEntry, content: String) -> some View {
        VStack(spacing: 0) {
            // Header with back button
            HStack {
                Button {
                    selectedFile = nil
                    fileContent = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.subheadline)
                }

                Spacer()

                Text(file.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                Spacer()

                // Placeholder for symmetry
                Text("Back").font(.subheadline).opacity(0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(platformGray6.opacity(0.5))

            Divider()

            // Content
            ScrollView {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private func navigateTo(_ url: URL) {
        selectedFile = nil
        fileContent = nil
        currentPath = url
        loadEntries()
    }

    private func loadEntries() {
        isLoading = true
        errorMessage = nil
        entries = []

        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(
                at: currentPath,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )

            entries = contents.compactMap { url -> FileEntry? in
                let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDir = resourceValues?.isDirectory ?? false
                let size = resourceValues?.fileSize
                return FileEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDir,
                    fileSize: isDir ? nil : size
                )
            }
            .sorted { a, b in
                // Directories first, then alphabetical
                if a.isDirectory != b.isDirectory {
                    return a.isDirectory
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func openFile(_ entry: FileEntry) {
        // Only open text-like files
        let textExtensions: Set<String> = [
            "txt", "md", "json", "jsonl", "yaml", "yml", "swift", "js", "ts", "py",
            "html", "css", "xml", "csv", "log", "sh", "zsh", "bash",
            "toml", "ini", "cfg", "conf", "env", "gitignore",
            "h", "m", "c", "cpp", "rs", "go", "rb", "java", "kt"
        ]

        let ext = entry.url.pathExtension.lowercased()
        let isTextFile = textExtensions.contains(ext) || ext.isEmpty

        if isTextFile {
            if let data = try? Data(contentsOf: entry.url),
               let text = String(data: data, encoding: .utf8) {
                // Limit preview to 100KB
                if text.count > 100_000 {
                    fileContent = String(text.prefix(100_000)) + "\n\n--- Truncated (file too large) ---"
                } else {
                    fileContent = text
                }
                selectedFile = entry
            } else {
                fileContent = "(Unable to read file as text)"
                selectedFile = entry
            }
        } else {
            fileContent = "(Binary file — \(entry.formattedSize ?? "unknown size"))"
            selectedFile = entry
        }
    }
}

// MARK: - File Entry Model

struct FileEntry: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int?

    var id: String { url.path }

    var icon: String {
        if isDirectory {
            return "folder.fill"
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "md": return "doc.text"
        case "json": return "curlybraces"
        case "yaml", "yml": return "list.bullet.rectangle"
        case "js", "ts": return "chevron.left.forwardslash.chevron.right"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "mp4", "mov", "avi": return "film"
        case "mp3", "wav", "aac": return "waveform"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz": return "archivebox"
        case "html", "css": return "globe"
        case "sh", "zsh", "bash": return "terminal"
        case "log": return "text.alignleft"
        default: return "doc"
        }
    }

    var iconColor: Color {
        if isDirectory { return .blue }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "swift": return .orange
        case "md": return .purple
        case "json": return .green
        case "yaml", "yml": return .teal
        case "js", "ts": return .yellow
        case "py": return Color(red: 0.2, green: 0.5, blue: 0.9)
        case "png", "jpg", "jpeg", "gif", "svg": return .pink
        case "mp4", "mov", "avi": return .red
        case "sh", "zsh", "bash": return .green
        default: return .secondary
        }
    }

    var formattedSize: String? {
        guard let size = fileSize else { return nil }
        if size < 1024 {
            return "\(size) B"
        } else if size < 1024 * 1024 {
            return String(format: "%.1f KB", Double(size) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FileExplorerView_Previews: PreviewProvider {
    static var previews: some View {
        FileExplorerView(
            rootURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        )
    }
}
#endif
