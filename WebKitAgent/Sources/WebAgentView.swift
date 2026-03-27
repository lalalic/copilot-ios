#if os(iOS)
import SwiftUI
import WebKit

/// A SwiftUI wrapper for WKWebView, driven by WebViewManager.
public struct WebAgentView: UIViewRepresentable {
    let manager: WebViewManager

    public init(manager: WebViewManager) {
        self.manager = manager
    }

    public func makeUIView(context: Context) -> WKWebView {
        manager.webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#elseif os(macOS)
import SwiftUI
import WebKit

/// A SwiftUI wrapper for WKWebView, driven by WebViewManager.
public struct WebAgentView: NSViewRepresentable {
    let manager: WebViewManager

    public init(manager: WebViewManager) {
        self.manager = manager
    }

    public func makeNSView(context: Context) -> WKWebView {
        manager.webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
