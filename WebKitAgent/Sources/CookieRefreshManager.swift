import Foundation
import WebKit

/// Periodically refreshes session cookies by navigating a hidden WebView to tracked domains.
/// Uses SharedWebKitEnvironment so refreshed cookies are available to all WebView instances.
@MainActor
public final class CookieRefreshManager {

    /// Domains being tracked for cookie refresh.
    public struct TrackedDomain: Sendable {
        public let site: String
        public let domain: String
        public let refreshURL: String
        public let requiredCookies: [String]?

        public init(site: String, domain: String, refreshURL: String, requiredCookies: [String]? = nil) {
            self.site = site
            self.domain = domain
            self.refreshURL = refreshURL
            self.requiredCookies = requiredCookies
        }
    }

    /// Result of a refresh attempt.
    public enum RefreshResult {
        case refreshed
        case expired(reason: String)
        case skipped(reason: String)
    }

    /// Callback when a domain's cookies expire.
    public var onSessionExpired: ((TrackedDomain) -> Void)?

    private var trackedDomains: [TrackedDomain] = []
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval

    /// Hidden WebView used for background cookie refresh.
    private var refreshWebView: WKWebView?
    private var navigationDelegate: RefreshNavigationDelegate?

    public init(refreshInterval: TimeInterval = 60 * 60) { // Default: every 60 min
        self.refreshInterval = refreshInterval
    }

    // MARK: - Public API

    /// Add a domain to track for cookie refresh.
    public func track(_ domain: TrackedDomain) {
        if !trackedDomains.contains(where: { $0.site == domain.site }) {
            trackedDomains.append(domain)
        }
    }

    /// Remove a domain from tracking.
    public func untrack(site: String) {
        trackedDomains.removeAll { $0.site == site }
    }

    /// Start the periodic refresh timer.
    public func start() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }
    }

    /// Stop the periodic refresh timer.
    public func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshWebView = nil
        navigationDelegate = nil
    }

    /// Get current status of all tracked domains.
    public func status() async -> [(site: String, loggedIn: Bool, cookieCount: Int)] {
        let store = SharedWebKitEnvironment.shared.dataStore.httpCookieStore
        let allCookies = await store.allCookies()

        return trackedDomains.map { tracked in
            let domainCookies = allCookies.filter { cookie in
                cookie.domain == tracked.domain ||
                cookie.domain == ".\(tracked.domain)" ||
                tracked.domain.hasSuffix(cookie.domain)
            }

            let loggedIn: Bool
            if let required = tracked.requiredCookies, !required.isEmpty {
                let present = Set(domainCookies.map { $0.name })
                loggedIn = required.allSatisfy { present.contains($0) }
            } else {
                loggedIn = !domainCookies.isEmpty
            }

            return (site: tracked.site, loggedIn: loggedIn, cookieCount: domainCookies.count)
        }
    }

    /// Refresh cookies for a single domain by navigating a hidden WebView to it.
    public func refresh(_ domain: TrackedDomain) async -> RefreshResult {
        let store = SharedWebKitEnvironment.shared.dataStore.httpCookieStore
        let cookiesBefore = await store.allCookies().filter {
            $0.domain == domain.domain || $0.domain == ".\(domain.domain)" || domain.domain.hasSuffix($0.domain)
        }

        // Only refresh if we had cookies (i.e., previously logged in)
        guard !cookiesBefore.isEmpty else {
            return .skipped(reason: "no cookies for \(domain.site)")
        }

        // Navigate hidden WebView to refresh URL
        let webView = getOrCreateRefreshWebView()
        guard let url = URL(string: domain.refreshURL) else {
            return .skipped(reason: "invalid refresh URL")
        }

        // Wait for navigation to complete (max 15s)
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.navigationDelegate?.pendingContinuation = continuation
            webView.load(URLRequest(url: url))

            // Timeout after 15s
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.navigationDelegate?.resumeIfPending(with: false)
            }
        }

        if !loaded {
            return .skipped(reason: "timeout loading \(domain.refreshURL)")
        }

        // Check if we still have the required cookies
        let cookiesAfter = await store.allCookies().filter {
            $0.domain == domain.domain || $0.domain == ".\(domain.domain)" || domain.domain.hasSuffix($0.domain)
        }

        if let required = domain.requiredCookies, !required.isEmpty {
            let present = Set(cookiesAfter.map { $0.name })
            let missing = required.filter { !present.contains($0) }
            if !missing.isEmpty {
                onSessionExpired?(domain)
                return .expired(reason: "missing cookies after refresh: \(missing.joined(separator: ", "))")
            }
        } else if cookiesAfter.isEmpty {
            onSessionExpired?(domain)
            return .expired(reason: "no cookies after refresh")
        }

        return .refreshed
    }

    // MARK: - Private

    /// Refresh all tracked domains.
    private func refreshAll() async {
        for domain in trackedDomains {
            _ = await refresh(domain)
        }
    }

    /// Get or create the hidden WebView for background refresh.
    private func getOrCreateRefreshWebView() -> WKWebView {
        if let existing = refreshWebView { return existing }
        let config = SharedWebKitEnvironment.shared.createConfiguration()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        let delegate = RefreshNavigationDelegate()
        wv.navigationDelegate = delegate
        self.navigationDelegate = delegate
        refreshWebView = wv
        return wv
    }
}

// MARK: - Navigation Delegate

/// Handles navigation callbacks for the hidden refresh WebView.
private final class RefreshNavigationDelegate: NSObject, WKNavigationDelegate {
    var pendingContinuation: CheckedContinuation<Bool, Never>?

    func resumeIfPending(with value: Bool) {
        guard let c = pendingContinuation else { return }
        pendingContinuation = nil
        c.resume(returning: value)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeIfPending(with: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeIfPending(with: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeIfPending(with: false)
    }
}
