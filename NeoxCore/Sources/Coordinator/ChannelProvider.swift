import Foundation
import CopilotSDK

/// Protocol for apps to plug in messaging channels (WeChat, Discord, etc.)
/// NeoxCore provides the infrastructure; apps provide channel implementations.
public protocol ChannelProvider: AnyObject, Sendable {
    var channelType: String { get }
    func send(message: String, to destination: String) async throws
}
