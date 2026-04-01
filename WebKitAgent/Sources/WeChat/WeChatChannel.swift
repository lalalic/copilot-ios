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

    private let webView: WKWebView
    private var bridgeInjected = false
    private var pollingTimer: Timer?
    private var heartbeatDeadline: Date?
    private var qrCheckTimer: Timer?

    private static let wechatURL = "https://wx.qq.com/"
    private static let pollInterval: TimeInterval = 0.5
    private static let heartbeatTimeout: TimeInterval = 45  // 3 missed 15s heartbeats
    private static let qrCheckInterval: TimeInterval = 1.0

    // MARK: - Init

    public override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // Persistent cookies
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif

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

        let request = URLRequest(url: URL(string: Self.wechatURL)!)
        webView.load(request)
    }

    /// Stop the WeChat channel and clean up.
    public func destroy() {
        stopPolling()
        stopQRCheck()
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
    ///   - content: Message text
    /// - Returns: Whether the message was sent successfully.
    public func sendMessage(to: String, content: String) async -> Bool {
        guard state == .ready else { return false }

        let script = WeChatBridge.sendScript(to: to, content: content)
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
        state = newState
        onStateChange?(newState)
    }

    // MARK: - Bridge Injection

    /// Attempt to inject the WechatyBro bridge into WeChat Web.
    private func tryInjectBridge() async {
        guard !bridgeInjected else { return }

        // Check if angular is ready
        do {
            let result = try await webView.evaluateJavaScript(WeChatBridge.angularCheckScript)
            guard let ready = result as? Bool, ready else {
                // Angular not ready yet, retry later
                return
            }
        } catch {
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

        return UIImage(ciImage: transformedImage)
    }
    #endif
}

// MARK: - WKNavigationDelegate

extension WeChatChannel: WKNavigationDelegate {
    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Page loaded — try to inject bridge
            await tryInjectBridge()
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in
            setState(.dead)
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in
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
        }
    }
}
