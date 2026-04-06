import SwiftUI
import WebKit

// MARK: - HTML Preview View

/// Full-screen modal that renders an HTML file in a WKWebView
/// with a mobile viewport (iPhone-sized). Used for mockup previews.
public struct HTMLPreviewView: View {

    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public var body: some View {
        NavigationView {
            HTMLWebView(fileURL: fileURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(fileURL.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - WKWebView Wrapper

#if canImport(UIKit)
struct HTMLWebView: UIViewRepresentable {
    let fileURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = true
        // Mobile viewport
        let viewport = """
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        """
        // Inject viewport if not already present
        if let data = try? Data(contentsOf: fileURL),
           let html = String(data: data, encoding: .utf8) {
            if html.lowercased().contains("<meta name=\"viewport\"") {
                webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            } else {
                let injected = viewport + html
                webView.loadHTMLString(injected, baseURL: fileURL.deletingLastPathComponent())
            }
        } else {
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#endif
