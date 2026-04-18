import Foundation

public enum SharedToolKit: String, CaseIterable, Sendable {
    case files
    case memory
    case subAgents
    case context
    case terminal
    case scripts
    case downloads
    case ffmpeg

    public static let defaultOrder: [SharedToolKit] = [
        .files,
        .memory,
        .subAgents,
        .context,
        .terminal,
        .scripts,
        .downloads,
        .ffmpeg,
    ]
}