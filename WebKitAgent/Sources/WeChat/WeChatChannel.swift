import Foundation
import WebKit
#if os(iOS)
import UIKit
import CoreImage
#endif

/// Manages a WeChat Web session in a dedicated WKWebView.
///
/// Port of bullx's `WechatManager` to WKWebView on iOS.
/// Key differences:
/// - No CDP — all communication via `evaluateJavaScript`
/// - QR code extracted from DOM instead of network interception
/// - iOS background execution limits apply
@MainActor
public final class WeChatChannel: NSObject, ObservableObject {

    // MARK: - Published State

    @Published public private(set) var state: WeChatChannelState = .disconnected
    @Published public private(set) var qrCodeURL: String?
    @Published public private(set) var loggedInUser: WeChatUser?
    @Published public private(set) var contacts: [WeChatContact] = []
    @Published public private(set) var messageCount: Int = 0

    // MARK: - Callbacks

    /// Called when a new message is received from WeChat.
    public var onMessage: (@Sendable (WeChatMessage) -> Void)?

    /// Called when channel state changes.
    public var onStateChange: (@Sendable (WeChatChannelState) -> Void)?

    // MARK: - Internal

    /// The underlying WKWebView. Expose for callers that need to add it
    /// to a window hierarchy (required on-device for page loads).
    public private(set) var webView: WKWebView
    private var bridgeInjected = false
    private var pollingTimer: Timer?
    private var heartbeatDeadline: Date?
    private var qrCheckTimer: Timer?
    private var directQRTimer: Timer?
    private var qrRefreshTimer: Timer?
    private var loginTimeoutTimer: Timer?

    private static let wechatURL = "https://wx.qq.com/"
    private static let pollInterval: TimeInterval = 0.5
    private static let heartbeatTimeout: TimeInterval = 45  // 3 missed 15s heartbeats
    private static let qrCheckInterval: TimeInterval = 1.0
    private static let directQRInterval: TimeInterval = 2.0
    private static let qrRefreshTimeout: TimeInterval = 4 * 60  // QR expires ~5min, refresh at 4
    private static let loginTimeout: TimeInterval = 30  // Fallback if login hangs after scan

    // MARK: - Init

    public override init() {
        // Use a dedicated process pool (not the shared one) to avoid
        // stale page cache from the browser. Each channel instance gets
        // a completely fresh WebKit process.
        let config = WKWebViewConfiguration()
        config.processPool = WKProcessPool()
        config.websiteDataStore = WKWebsiteDataStore.default()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        #endif
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        self.webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
            configuration: config
        )
        super.init()

        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.navigationDelegate = self
    }

    // MARK: - Public API

    /// Start the WeChat channel — loads wx.qq.com and begins QR flow.
    public func start() {
        guard state == .disconnected || state == .dead else { return }

        setState(.loading)
        bridgeInjected = false
        qrCodeURL = nil
        loggedInUser = nil

        var request = URLRequest(url: URL(string: Self.wechatURL)!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        webView.load(request)

        // wx.qq.com never finishes loading (perpetual long-polling), so
        // `didFinish` WKNavigationDelegate will never fire.
        // Start bridge injection retries and QR extraction immediately.
        startBridgeRetry()
        startDirectQRExtraction()
    }

    /// Stop the WeChat channel and clean up.
    public func destroy() {
        stopPolling()
        stopQRCheck()
        stopBridgeRetry()
        stopDirectQR()
        qrRefreshTimer?.invalidate()
        qrRefreshTimer = nil
        loginTimeoutTimer?.invalidate()
        loginTimeoutTimer = nil
        webView.stopLoading()
        bridgeInjected = false
        qrCodeURL = nil
        loggedInUser = nil
        contacts = []
        messageCount = 0
        setState(.disconnected)
    }

    /// Send a message to a contact.
    /// - Parameters:
    ///   - to: Contact UserName, PYQuanPin, or "filehelper"
    ///   - content: Message text (markdown is auto-converted to Unicode styling)
    ///   - watermark: If true, adds invisible AI watermark to the message
    /// - Returns: Whether the message was sent successfully.
    public func sendMessage(to: String, content: String, watermark: Bool = false) async -> Bool {
        guard state == .ready else { return false }

        let script = WeChatBridge.sendScript(to: to, content: content, watermark: watermark)
        do {
            let result = try await webView.evaluateJavaScript(script)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool {
                return ok
            }
        } catch {
            // JS evaluation failed
        }
        return false
    }

    /// Get the current contact list from WeChat.
    public func getContacts() async -> [WeChatContact] {
        guard state == .ready else { return [] }

        do {
            let result = try await webView.evaluateJavaScript(WeChatBridge.contactsScript)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let parsed = json.compactMap { dict -> WeChatContact? in
                    guard let id = dict["id"] as? String,
                          let userName = dict["UserName"] as? String else { return nil }
                    return WeChatContact(
                        id: id,
                        name: dict["name"] as? String ?? dict["NickName"] as? String ?? "",
                        userName: userName,
                        nickName: dict["NickName"] as? String,
                        remarkName: dict["RemarkName"] as? String,
                        headImgUrl: dict["HeadImgUrl"] as? String,
                        isRoom: dict["isRoomContact"] as? Bool ?? false,
                        sex: dict["Sex"] as? Int ?? 0
                    )
                }
                contacts = parsed
                return parsed
            }
        } catch {
            // JS evaluation failed
        }
        return []
    }

    /// Restart the channel (e.g., after session expiry).
    public func restart() {
        destroy()
        start()
    }

    // MARK: - State Machine

    private func setState(_ newState: WeChatChannelState) {
        print("[WeChatChannel] state: \(state.rawValue) → \(newState.rawValue)")
        state = newState
        onStateChange?(newState)

        // Start login timeout when entering loggingIn state
        loginTimeoutTimer?.invalidate()
        loginTimeoutTimer = nil
        if newState == .loggingIn {
            loginTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.loginTimeout, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.state == .loggingIn else { return }
                    print("[WeChatChannel] Login timed out after \(Self.loginTimeout)s — refreshing QR")
                    await self.refreshQRCode()
                }
            }
        }
    }

    private var bridgeRetryTimer: Timer?
    private static let bridgeRetryInterval: TimeInterval = 2.0
    private static let bridgeMaxRetries: Int = 15

    private var bridgeRetryCount = 0

    private func startBridgeRetry() {
        stopBridgeRetry()
        bridgeRetryCount = 0
        bridgeRetryTimer = Timer.scheduledTimer(withTimeInterval: Self.bridgeRetryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.bridgeInjected else {
                    self?.stopBridgeRetry()
                    return
                }
                self.bridgeRetryCount += 1
                if self.bridgeRetryCount > Self.bridgeMaxRetries {
                    self.stopBridgeRetry()
                    return
                }
                await self.tryInjectBridge()
            }
        }
    }

    private func stopBridgeRetry() {
        bridgeRetryTimer?.invalidate()
        bridgeRetryTimer = nil
    }

    // MARK: - Bridge Injection

    /// Attempt to inject the WechatyBro bridge into WeChat Web.
    private func tryInjectBridge() async {
        guard !bridgeInjected else { return }

        // Check if angular is ready
        do {
            let result = try await webView.evaluateJavaScript(WeChatBridge.angularCheckScript)
            guard let ready = result as? Bool, ready else {
                print("[WeChatChannel] tryInjectBridge: angular not ready yet")
                return
            }
            print("[WeChatChannel] tryInjectBridge: angular IS ready!")
        } catch {
            print("[WeChatChannel] tryInjectBridge: angular check error: \(error.localizedDescription)")
            return
        }

        // Inject the bridge
        do {
            let result = try await webView.evaluateJavaScript(WeChatBridge.injectionScript)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["code"] as? Int {
                if code == 200 || code == 304 {
                    bridgeInjected = true
                    startPolling()

                    // Check if already logged in
                    let loggedIn = try? await webView.evaluateJavaScript(WeChatBridge.loginCheckScript) as? Bool
                    if loggedIn == true {
                        setState(.ready)
                    } else {
                        setState(.extractingQR)
                        startQRCheck()
                    }
                }
            }
        } catch {
            // Injection failed
        }
    }

    // MARK: - QR Code Extraction

    private func startQRCheck() {
        stopQRCheck()
        qrCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.qrCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkQRCode()
            }
        }
    }

    private func stopQRCheck() {
        qrCheckTimer?.invalidate()
        qrCheckTimer = nil
    }

    private func checkQRCode() async {
        guard state == .extractingQR || state == .qrReady else {
            stopQRCheck()
            return
        }

        do {
            let result = try await webView.evaluateJavaScript(WeChatBridge.qrCodeScript)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let url = json["url"] as? String, !url.isEmpty {
                    qrCodeURL = url
                    if state != .qrReady {
                        setState(.qrReady)
                    }
                }
                // Code 201 = scanned, waiting for confirm
                if let code = json["code"] as? Int, code == 201 {
                    setState(.loggingIn)
                    stopQRCheck()
                }
            }
        } catch {
            // QR check failed
        }
    }

    // MARK: - Direct QR Extraction (pre-bridge)

    /// Extract QR UUID directly from DOM/JS variables without requiring the bridge.
    /// wx.qq.com never fires didFinish, so this timer starts immediately from start().
    private func startDirectQRExtraction() {
        stopDirectQR()
        directQRTimer = Timer.scheduledTimer(withTimeInterval: Self.directQRInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.extractQRDirect()
            }
        }
    }

    private func stopDirectQR() {
        directQRTimer?.invalidate()
        directQRTimer = nil
    }

    private func extractQRDirect() async {
        // Stop once bridge takes over or we're logged in
        guard !bridgeInjected, state == .loading || state == .extractingQR || state == .qrReady || state == .loggingIn else {
            print("[WeChatChannel] extractQRDirect: stopping (bridgeInjected=\(bridgeInjected), state=\(state.rawValue))")
            stopDirectQR()
            return
        }

        // Also check page title and readyState for debugging
        if let title = try? await webView.evaluateJavaScript("document.title") as? String,
           let ready = try? await webView.evaluateJavaScript("document.readyState") as? String {
            print("[WeChatChannel] extractQRDirect: title='\(title)' readyState=\(ready) url=\(webView.url?.absoluteString ?? "nil")")
        }

        // When QR is already shown or user has scanned, try to detect login.
        if state == .qrReady || state == .loggingIn {
            // 1. Try direct login check (works even without Angular bridge)
            if let loggedIn = try? await webView.evaluateJavaScript(WeChatBridge.loginCheckScript) as? Bool,
               loggedIn {
                print("[WeChatChannel] extractQRDirect: login detected via MMCgi!")
                // Try to inject bridge for full functionality
                await tryInjectBridge()
                if !bridgeInjected {
                    // Bridge injection failed, but we know we're logged in
                    setState(.ready)
                }
                stopDirectQR()
                return
            }

            // 2. Try bridge injection (angular may have become ready after login)
            await tryInjectBridge()
            if bridgeInjected {
                stopDirectQR()
                return
            }

            // 3. Check for scan confirmation (code 201) via the login page script
            if let result = try? await webView.evaluateJavaScript(WeChatBridge.qrCodeScript) as? String,
               let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["code"] as? Int, code == 201 {
                print("[WeChatChannel] extractQRDirect: scan detected (code 201)!")
                setState(.loggingIn)
            }
        }

        do {
            let result = try await webView.evaluateJavaScript(WeChatBridge.directQRExtractionScript)
            if let str = result as? String {
                print("[WeChatChannel] directQR result: \(str)")
                if let data = str.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let uuid = json["uuid"] as? String, !uuid.isEmpty {
                    // Build the scan URL from UUID
                    let scanURL = "https://login.weixin.qq.com/l/\(uuid)"
                    if qrCodeURL != scanURL {
                        print("[WeChatChannel] QR found! UUID=\(uuid)")
                        qrCodeURL = scanURL
                        if state != .qrReady {
                            setState(.qrReady)
                        }
                        scheduleQRRefresh()
                    }
                }
            }
        } catch {
            print("[WeChatChannel] extractQRDirect error: \(error.localizedDescription)")
        }
    }

    // MARK: - QR Refresh (expiry handling)

    private func scheduleQRRefresh() {
        qrRefreshTimer?.invalidate()
        qrRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.qrRefreshTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshQRCode()
            }
        }
    }

    private func refreshQRCode() async {
        guard state == .qrReady || state == .extractingQR || state == .loggingIn else { return }

        // Try clicking the expired overlay first
        do {
            let result = try await webView.evaluateJavaScript(WeChatBridge.qrRefreshScript)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let refreshed = json["refreshed"] as? Bool, refreshed {
                // Overlay clicked — wait for new QR to appear
                setState(.extractingQR)
                qrCodeURL = nil
                return
            }
        } catch {
            // JS eval failed
        }

        // Fallback: full page reload
        qrCodeURL = nil
        setState(.loading)
        bridgeInjected = false
        var request = URLRequest(url: URL(string: Self.wechatURL)!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        webView.load(request)
        startBridgeRetry()
        startDirectQRExtraction()
    }

    // MARK: - Message Polling

    private func startPolling() {
        stopPolling()
        heartbeatDeadline = Date().addingTimeInterval(Self.heartbeatTimeout)

        pollingTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollBridge()
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func pollBridge() async {
        // Check heartbeat timeout
        if let deadline = heartbeatDeadline, Date() > deadline {
            setState(.dead)
            stopPolling()
            return
        }

        do {
            let result = try await webView.evaluateJavaScript(WeChatBridge.pollScript)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for eventDict in events {
                    if let event = WeChatBridgeEvent.parse(eventDict) {
                        handleEvent(event)
                    }
                }
            }
        } catch {
            // Polling failed — webView might have been reclaimed
        }
    }

    private func handleEvent(_ event: WeChatBridgeEvent) {
        switch event {
        case .scan(let code, let url):
            qrCodeURL = url
            if code == 201 {
                setState(.loggingIn)
                stopQRCheck()
            } else if state != .qrReady {
                setState(.qrReady)
            }

        case .login(let user):
            loggedInUser = user
            setState(.ready)
            stopQRCheck()
            // Fetch contacts after login
            Task {
                _ = await getContacts()
            }

        case .logout:
            loggedInUser = nil
            contacts = []
            setState(.dead)
            stopPolling()

        case .message(let msg):
            messageCount += 1
            onMessage?(msg)

        case .heartbeat:
            heartbeatDeadline = Date().addingTimeInterval(Self.heartbeatTimeout)

        case .contacts(let count):
            _ = count // Contacts loaded, we'll fetch them separately

        case .contactsReady:
            // wechat-bro.js has built stable ID maps — contacts are fully ready
            Task {
                _ = await getContacts()
            }

        case .error(let msg):
            _ = msg // TODO: Log or surface errors
        }
    }

    // MARK: - QR Code Generation

    #if os(iOS)
    /// Generate a QR code UIImage from a string.
    public static func generateQRCode(from string: String, size: CGFloat = 200) -> UIImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }

        let scaleX = size / ciImage.extent.size.width
        let scaleY = size / ciImage.extent.size.height
        let transformedImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // CIImage-backed UIImage doesn't render in SwiftUI — convert through CGImage
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformedImage, from: transformedImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif
}

// MARK: - WKNavigationDelegate

extension WeChatChannel: WKNavigationDelegate {
    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            print("[WeChatChannel] didFinish navigation, URL: \(webView.url?.absoluteString ?? "nil")")
            await tryInjectBridge()
            if !bridgeInjected {
                startBridgeRetry()
            }
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in
            print("[WeChatChannel] didFail navigation: \(error.localizedDescription)")
            setState(.dead)
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in
            print("[WeChatChannel] didFailProvisionalNavigation: \(error.localizedDescription)")
            setState(.dead)
        }
    }

    /// Handle WKWebView process termination (iOS memory pressure).
    public nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            bridgeInjected = false
            setState(.dead)
            stopPolling()
            stopQRCheck()
            stopBridgeRetry()
            stopDirectQR()
            qrRefreshTimer?.invalidate()
            qrRefreshTimer = nil
        }
    }
}
