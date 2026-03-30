import SwiftUI
import WebKit

// MARK: - Mermaid View

/// Renders mermaid diagram source code as inline SVG using WKWebView + mermaid.js.
/// Automatically resizes to fit the rendered diagram.
public struct MermaidView: View {

    private let source: String
    @State private var height: CGFloat = 200

    public init(source: String) {
        self.source = source
    }

    public var body: some View {
        MermaidWebView(source: source, height: $height)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(platformGray6)
            )
    }
}

// MARK: - WKWebView Wrapper

#if canImport(UIKit)
private struct MermaidWebView: UIViewRepresentable {
    let source: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "heightChanged")
        config.userContentController.add(context.coordinator, name: "ready")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.pendingSource = source

        // Load the mermaid HTML from bundle
        if let htmlURL = Bundle.module.url(forResource: "mermaid", withExtension: "html", subdirectory: "Resources") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            // Fallback: load from string
            let html = Self.fallbackHTML
            webView.loadHTMLString(html, baseURL: nil)
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.pendingSource != source {
            context.coordinator.pendingSource = source
            context.coordinator.renderDiagram()
        }
    }

    static let fallbackHTML = """
    <!DOCTYPE html><html><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
    <style>body{margin:0;display:flex;justify-content:center;background:transparent}svg{max-width:100%}</style>
    </head><body>
    <div id="mermaid-container"><pre class="mermaid" id="diagram"></pre></div>
    <script>
    mermaid.initialize({startOnLoad:false,theme:'default',securityLevel:'loose'});
    async function renderDiagram(s){try{const{svg}=await mermaid.render('r',s);document.getElementById('mermaid-container').innerHTML=svg;window.webkit?.messageHandlers?.heightChanged?.postMessage(document.getElementById('mermaid-container').scrollHeight)}catch(e){document.getElementById('mermaid-container').innerHTML='<p style="color:red">'+e.message+'</p>';window.webkit?.messageHandlers?.heightChanged?.postMessage(60)}}
    window.webkit?.messageHandlers?.ready?.postMessage(true);
    </script></body></html>
    """
}

#elseif canImport(AppKit)
private struct MermaidWebView: NSViewRepresentable {
    let source: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "heightChanged")
        config.userContentController.add(context.coordinator, name: "ready")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.pendingSource = source

        if let htmlURL = Bundle.module.url(forResource: "mermaid", withExtension: "html", subdirectory: "Resources") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.pendingSource != source {
            context.coordinator.pendingSource = source
            context.coordinator.renderDiagram()
        }
    }
}
#endif

// MARK: - Coordinator

private class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Binding var height: CGFloat
    weak var webView: WKWebView?
    var pendingSource: String = ""
    private var isReady = false

    init(height: Binding<CGFloat>) {
        _height = height
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "heightChanged", let h = message.body as? CGFloat {
            Task { @MainActor in
                self.height = max(h + 16, 60) // Add padding
            }
        } else if message.name == "ready" {
            isReady = true
            renderDiagram()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Page loaded — render if ready message hasn't fired
        if !isReady {
            isReady = true
            renderDiagram()
        }
    }

    func renderDiagram() {
        guard isReady, !pendingSource.isEmpty else { return }
        let escaped = pendingSource
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        webView?.evaluateJavaScript("renderDiagram('\(escaped)')")
    }
}
