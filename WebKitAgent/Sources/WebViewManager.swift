import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// Manages a WKWebView instance for agent-driven browser automation.
/// Handles navigation, JavaScript evaluation, downloads, and page lifecycle.
@MainActor
public final class WebViewManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published public var currentURL: URL?
    @Published public var pageTitle: String = ""
    @Published public var isLoading = false

    // MARK: - WebView

    public let webView: WKWebView

    // MARK: - Internal State

    /// Current element refs from last snapshot.
    private(set) var currentRefs: [String: String] = [:] // ref → description

    /// Navigation continuation for async load waiting.
    private var navigationContinuation: CheckedContinuation<Void, any Error>?

    /// Callback-based navigation completion (used with timeout).
    var onNavigationComplete: (() -> Void)?

    /// Download handling.
    private var downloadContinuation: CheckedContinuation<URL?, Never>?
    private var downloadDestination: URL?

    /// Upload handling — pre-loaded file URLs for the file picker delegate.
    var pendingUploadURLs: [URL]?

    /// Directory for downloaded files.
    public let downloadsDirectory: URL

    // MARK: - Init

    public override init() {
        let config = SharedWebKitEnvironment.shared.createConfiguration()

        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        self.downloadsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKitAgent", isDirectory: true)

        super.init()

        // Use desktop user-agent so sites serve their full desktop version
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        // Enable Safari Web Inspector (desktop Safari → Develop → iPhone → Intento)
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Create downloads directory
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Window Attachment

    /// Attach the webView to the app's active key window as a hidden subview.
    /// This is required on iOS for proper WebKit layout/rendering of headless
    /// pages — many sites (TikTok, YouTube Studio) defer file-input pipelines
    /// and dynamic widgets until the WKWebView has a real superview/window.
    /// Idempotent: no-op if already attached.
    public func attachToActiveWindow() {
        #if canImport(UIKit)
        guard webView.superview == nil else { return }
        // Find the active foreground key window across connected scenes.
        let scenes = UIApplication.shared.connectedScenes
        let keyWindow = scenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? scenes
                .compactMap { ($0 as? UIWindowScene)?.windows.first }
                .first
        guard let window = keyWindow else { return }
        // Layout-driving size, but invisible and non-interactive so it doesn't
        // intercept touches or affect the visible UI.
        webView.frame = CGRect(x: 0, y: 0, width: 1280, height: 900)
        webView.alpha = 1.0
        webView.isUserInteractionEnabled = false
        // Insert at the bottom so it sits behind every visible view.
        window.insertSubview(webView, at: 0)
        #endif
    }

    // MARK: - Navigation

    /// Navigate to a URL. Waits for page load to complete (with 30s timeout).
    public func navigate(to urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw WebAgentError.invalidURL(urlString)
        }

        isLoading = true
        let request = URLRequest(url: url)
        webView.load(request)

        // Wait for navigation to complete with timeout
        let timedOut: Bool = await withCheckedContinuation { continuation in
            var resumed = false

            // Set a callback for when navigation finishes
            self.onNavigationComplete = {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: false)
            }

            // Timeout after 30 seconds
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !resumed else { return }
                resumed = true
                self?.onNavigationComplete = nil
                continuation.resume(returning: true)
            }
        }

        onNavigationComplete = nil
        isLoading = false
        currentURL = webView.url
        pageTitle = webView.title ?? ""

        let suffix = timedOut ? " (timed out, page may still be loading)" : ""
        return "Page loaded: \(pageTitle) (\(webView.url?.absoluteString ?? urlString))\(suffix)"
    }

    // MARK: - Snapshot

    /// Take a DOM snapshot — scans interactive elements and assigns @refs.
    /// Returns a text listing of all interactive elements.
    public func snapshot() async throws -> String {
        let js = DOMSnapshot.snapshotScript
        let resultJSON = try await evaluateJS(js)

        guard let data = resultJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String,
              let url = json["url"] as? String,
              let count = json["count"] as? Int,
              let refs = json["refs"] as? [String] else {
            return "Failed to parse snapshot."
        }

        // Store refs for lookup
        currentRefs.removeAll()
        for ref in refs {
            if let refId = ref.split(separator: " ").first {
                currentRefs[String(refId)] = ref
            }
        }

        var output = "Page: \(title)\nURL: \(url)\n\n"
        output += refs.joined(separator: "\n")
        output += "\n(\(count) interactive elements)"

        return output
    }

    // MARK: - Click

    /// Click an element by its @ref.
    public func click(ref: String) async throws -> String {
        let js = DOMSnapshot.clickScript(ref: ref)
        let resultJSON = try await evaluateJS(js)

        guard let data = resultJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Click failed: could not parse result."
        }

        if let error = json["error"] as? String {
            return "Click failed: \(error) (ref: \(ref)). Try snapshot() to refresh refs."
        }

        let tag = json["tag"] as? String ?? "?"
        let text = json["text"] as? String ?? ""

        // Wait briefly for any navigation/re-render
        try? await Task.sleep(for: .milliseconds(300))

        return "Clicked \(ref) [\(tag)] \"\(text)\""
    }

    // MARK: - Type

    /// Type text into an element by its @ref.
    public func type(ref: String, text: String, clear: Bool = true) async throws -> String {
        let js = DOMSnapshot.typeScript(ref: ref, text: text, clear: clear)
        let resultJSON = try await evaluateJS(js)

        guard let data = resultJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Type failed: could not parse result."
        }

        if let error = json["error"] as? String {
            return "Type failed: \(error) (ref: \(ref)). Try snapshot() to refresh refs."
        }

        let value = json["value"] as? String ?? text
        return "Typed \"\(text)\" into \(ref) (value: \"\(value)\")"
    }

    // MARK: - Download

    /// Download a file by @ref (extracts href) or direct URL.
    public func download(ref: String? = nil, url: String? = nil, filename: String? = nil) async throws -> String {
        var downloadURL: URL?
        var suggestedName = filename

        if let ref {
            // Extract href from element
            let js = """
            (function() {
                const el = document.querySelector('[data-wa-ref="\(ref)"]');
                if (!el) return JSON.stringify({error: 'not_found'});
                const href = el.href || el.src || el.getAttribute('href');
                if (!href) return JSON.stringify({error: 'no_href'});
                const text = (el.textContent || '').trim().substring(0, 40);
                const download = el.getAttribute('download') || '';
                return JSON.stringify({href: href, text: text, download: download});
            })()
            """
            let resultJSON = try await evaluateJS(js)
            guard let data = resultJSON.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WebAgentError.downloadFailed("Could not extract URL from \(ref)")
            }
            if let error = json["error"] as? String {
                throw WebAgentError.downloadFailed(error)
            }
            if let href = json["href"] as? String {
                downloadURL = URL(string: href, relativeTo: webView.url)
            }
            if suggestedName == nil, let dl = json["download"] as? String, !dl.isEmpty {
                suggestedName = dl
            }
        } else if let url {
            downloadURL = URL(string: url)
        }

        guard let finalURL = downloadURL else {
            throw WebAgentError.downloadFailed("No valid URL to download")
        }

        // Download via URLSession with WKWebView cookies
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        var request = URLRequest(url: finalURL)
        if !cookies.isEmpty {
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.addValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        // Carry referrer
        if let currentURL = webView.url {
            request.addValue(currentURL.absoluteString, forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        // Determine filename
        let name = suggestedName
            ?? response.suggestedFilename
            ?? finalURL.lastPathComponent

        let destURL = downloadsDirectory.appendingPathComponent(name)
        try data.write(to: destURL)

        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let status = httpResponse?.statusCode ?? 200

        return "Downloaded: \(name) (\(sizeStr), HTTP \(status)) → \(destURL.path)"
    }

    // MARK: - Upload

    /// Preload file URLs for the next file chooser interaction.
    public func prepareUpload(urls: [URL]) {
        pendingUploadURLs = urls
    }

    /// Clear any preloaded file chooser URLs.
    public func clearPreparedUpload() {
        pendingUploadURLs = nil
    }

    /// Trigger a file upload on a file input element.
    public func upload(ref: String, filePath: String) async throws -> String {
        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw WebAgentError.fileNotFound(filePath)
        }

        // Pre-load the file URL for the delegate
        pendingUploadURLs = [fileURL]

        // Click the file input to trigger the picker
        let js = """
        (function() {
            const el = document.querySelector('[data-wa-ref="\(ref)"]');
            if (!el) return JSON.stringify({error: 'not_found'});
            if (el.tagName.toLowerCase() !== 'input' || el.type !== 'file') {
                return JSON.stringify({error: 'not_file_input'});
            }
            el.click();
            return JSON.stringify({ok: true});
        })()
        """
        let resultJSON = try await evaluateJS(js)
        guard let data = resultJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebAgentError.uploadFailed("Could not trigger file input")
        }
        if let error = json["error"] as? String {
            throw WebAgentError.uploadFailed(error)
        }

        // Wait for upload to process
        try? await Task.sleep(for: .milliseconds(500))
        pendingUploadURLs = nil

        return "Uploaded: \(fileURL.lastPathComponent) to \(ref)"
    }

    // MARK: - Screenshot

    /// Take a screenshot of the current page as PNG base64.
    public func screenshot(quality: CGFloat = 0.1) async -> String? {
        #if os(iOS)
        let config = WKSnapshotConfiguration()
        guard let image = try? await webView.takeSnapshot(configuration: config),
              let data = image.pngData() else {
            return nil
        }
        return data.base64EncodedString()
        #elseif os(macOS)
        let config = WKSnapshotConfiguration()
        guard let image = try? await webView.takeSnapshot(configuration: config) else {
            return nil
        }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return data.base64EncodedString()
        #endif
    }

    // MARK: - Cookies & Auth

    /// Get all cookies for a specific domain.
    public func getCookies(for domain: String) async -> [HTTPCookie] {
        let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return allCookies.filter { cookie in
            cookie.domain == domain || cookie.domain == ".\(domain)" || domain.hasSuffix(cookie.domain)
        }
    }

    /// Check if we have session cookies for a domain (i.e., user is probably logged in).
    /// Returns a dictionary with `loggedIn` (bool) + domain-specific details.
    public func checkAuth(domain: String, cookieNames: [String]? = nil) async -> [String: Any] {
        let cookies = await getCookies(for: domain)
        if cookies.isEmpty {
            return ["loggedIn": false, "domain": domain, "reason": "no cookies"]
        }
        // If specific cookie names are required, check for them
        if let required = cookieNames, !required.isEmpty {
            let present = Set(cookies.map { $0.name })
            let missing = required.filter { !present.contains($0) }
            if !missing.isEmpty {
                return ["loggedIn": false, "domain": domain, "reason": "missing cookies: \(missing.joined(separator: ", "))"]
            }
        }
        // Has cookies → probably logged in. Return cookie names for debugging.
        let names = cookies.map { $0.name }.sorted()
        return ["loggedIn": true, "domain": domain, "cookieCount": cookies.count, "cookies": names]
    }

    /// Get login status for multiple domains at once.
    public func sessionStatus(domains: [(site: String, domain: String, requiredCookies: [String]?)]) async -> [[String: Any]] {
        var results: [[String: Any]] = []
        for entry in domains {
            var status = await checkAuth(domain: entry.domain, cookieNames: entry.requiredCookies)
            status["site"] = entry.site
            results.append(status)
        }
        return results
    }

    /// Clear all cookies for a specific domain (logout).
    public func clearCookies(for domain: String) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        for cookie in cookies {
            if cookie.domain == domain || cookie.domain == ".\(domain)" || domain.hasSuffix(cookie.domain) {
                await store.deleteCookie(cookie)
            }
        }
    }

    // MARK: - Helpers

    private func evaluateJS(_ js: String) async throws -> String {
        let result = try await webView.evaluateJavaScript(js)
        if let str = result as? String {
            return str
        }
        return String(describing: result ?? "null")
    }

    /// Public wrapper for evaluateJS, used by site adapters.
    public func evaluateJSPublic(_ js: String) async throws -> String {
        try await evaluateJS(js)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewManager: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url
        pageTitle = webView.title ?? ""
        isLoading = false
        navigationContinuation?.resume()
        navigationContinuation = nil
        onNavigationComplete?()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        isLoading = false
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
        onNavigationComplete?()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        isLoading = false
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
        onNavigationComplete?()
    }

    // Handle download initiation
    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - WKDownloadDelegate

extension WebViewManager: WKDownloadDelegate {
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let dest = downloadsDirectory.appendingPathComponent(suggestedFilename)
        downloadDestination = dest
        return dest
    }

    public func downloadDidFinish(_ download: WKDownload) {
        downloadContinuation?.resume(returning: downloadDestination)
        downloadContinuation = nil
        downloadDestination = nil
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        downloadContinuation?.resume(returning: nil)
        downloadContinuation = nil
        downloadDestination = nil
    }
}

// MARK: - WKUIDelegate

extension WebViewManager: WKUIDelegate {
    #if os(macOS) || os(iOS)
    @available(iOS 18.4, *)
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        // Return pre-loaded file URLs for upload
        let urls = pendingUploadURLs
        pendingUploadURLs = nil
        return urls
    }
    #endif
}

// MARK: - Errors

public enum WebAgentError: Error, LocalizedError {
    case invalidURL(String)
    case downloadFailed(String)
    case uploadFailed(String)
    case fileNotFound(String)
    case javaScriptError(String)
    case navigationTimeout(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .downloadFailed(let reason): return "Download failed: \(reason)"
        case .uploadFailed(let reason): return "Upload failed: \(reason)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .javaScriptError(let msg): return "JavaScript error: \(msg)"
        case .navigationTimeout(let url): return "Navigation timed out (30s): \(url)"
        }
    }
}
