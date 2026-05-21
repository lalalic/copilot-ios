import Foundation

/// A locally-recorded reference voice that has been (or can be) cloned via Ali DashScope.
public struct VoiceClone: Codable, Identifiable, Equatable, Sendable {
    public var id: String           // local stable id (UUID)
    public var name: String         // user-facing label, e.g. "My voice", "Mom"
    public var sampleURL: String    // public URL of the reference audio (Ali fetches from this)
    public var aliVoiceId: String?  // resolved by /voice/clone (cached after first use)
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                sampleURL: String,
                aliVoiceId: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sampleURL = sampleURL
        self.aliVoiceId = aliVoiceId
        self.createdAt = createdAt
    }
}
