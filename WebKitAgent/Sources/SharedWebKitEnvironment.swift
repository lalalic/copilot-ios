import WebKit

/// Singleton that provides shared WebKit configuration for cookie sharing across all WebView instances.
/// All WKWebViews using this configuration share the same process pool and data store,
/// enabling cookie sharing between site adapters, WeChat, and browser views.
@MainActor
public final class SharedWebKitEnvironment: Sendable {
    public static let shared = SharedWebKitEnvironment()

    public let processPool = WKProcessPool()
    public let dataStore = WKWebsiteDataStore.default()

    private init() {}

    /// Creates a new WKWebViewConfiguration with shared process pool and data store.
    /// Each caller can further customize the returned configuration (e.g., add user scripts).
    public func createConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = dataStore
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        #endif
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        return config
    }
}
