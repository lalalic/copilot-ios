import SwiftUI

/// Displays app title with connection status indicator color.
/// Green when connected, secondary when disconnected/connecting.
public struct ConnectionTitleView: View {
    let title: String
    @ObservedObject var viewModel: ChatViewModel

    public init(title: String, viewModel: ChatViewModel) {
        self.title = title
        self.viewModel = viewModel
    }

    public var body: some View {
        let connected = viewModel.chatState != .disconnected && viewModel.chatState != .connecting
        Text(title)
            .font(.headline)
            .foregroundStyle(connected ? .green : .secondary)
    }
}
