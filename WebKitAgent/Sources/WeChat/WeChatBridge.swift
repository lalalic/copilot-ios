import Foundation
import WebKit
#if os(iOS)
import UIKit
import CoreImage
#endif

/// Manages a WeChat Web session in a dedicated WKWebView.
///
/// Unified bridge: JS templates + WKWebView lifecycle + event handling in one class.
/// Architecture follows wechat-bro/README.md "Option 5: In iOS WebKit".
///
/// Communication:
/// - JS → Swift: WKScriptMessageHandler (`wechatEvent`)
/// - Swift → JS: `evaluateJavaScript`
///
/// State machine:
///   disconnected → loading → (bridge injects, scan event pushes QR)
///   → qrReady → (scan 201) → loggingIn → (login event) → ready
@MainActor
public final class WeChatBridge: NSObject, ObservableObject {

    // MARK: - Published State

    @Published public private(set) var state: WeChatChannelState = .disconnected
    @Published public private(set) var qrCodeURL: String?
    @Published public private(set) var loggedInUser: WeChatUser?
    @Published public private(set) var contacts: [WeChatContact] = []
    @Published public private(set) var messageCount: Int = 0

    // MARK: - Callbacks

    public var onMessage: (@Sendable (WeChatMessage) -> Void)?
    public var onStateChange: (@Sendable (WeChatChannelState) -> Void)?

    // MARK: - Internal

    public private(set) var webView: WKWebView

    private var bridgeInjected = false
    private var bridgeRetryTimer: Timer?
    private var bridgeRetryCount = 0
    private var heartbeatTimer: Timer?
    private var heartbeatDeadline: Date?
    private var qrRefreshTimer: Timer?

    private static let wechatURL = "https://wx.qq.com/"
    private static let heartbeatTimeout: TimeInterval = 45
    private static let bridgeRetryInterval: TimeInterval = 2.0
    private static let bridgeMaxRetries: Int = 15
    private static let qrRefreshTimeout: TimeInterval = 4 * 60

    // MARK: - JS Sources

    private static let wechatBroSource: String = {
        guard let url = Bundle.main.url(forResource: "wechat-bro", withExtension: "js"),
              let code = try? String(contentsOf: url, encoding: .utf8) else {
            print("[WeChatBridge] FATAL: wechat-bro.js not found in app bundle")
            return ""
        }
        return code
    }()

    /// JavaScript source for the bridge user script (injected at document start).
    static let bridgeSource: String = """
    window.sendToPuppeteer = function(event, data) {
        window.webkit.messageHandlers.wechatEvent.postMessage({
            event: event,
            data: data
        });
    };
    """

    /// Inject wechat-bro.js and call WechatyBro.init().
    static var injectionScript: String {
        """
        \(wechatBroSource)

        ;(function() {
          if (window.WechatyBro && window.WechatyBro.init) {
            var result = window.WechatyBro.init();
            return JSON.stringify(result || {code: 200, message: 'ok'});
          }
          return JSON.stringify({code: 503, message: 'WechatyBro not found after injection'});
        })()
        """
    }

    static let angularCheckScript: String = """
    (function() {
      return !!(typeof angular !== 'undefined' && angular.element && angular.element(document).injector());
    })()
    """

    static let loginCheckScript: String = """
    (function() {
      return !!(window.MMCgi && window.MMCgi.isLogin);
    })()
    """

    static let qrRefreshScript: String = """
    (function() {
      try {
        var overlay = document.querySelector(
          '.qrcode .expired, .qrcode_expired_mask, [ng-click*="getQRCode"], .QRCode .mask'
        );
        if (overlay) { overlay.click(); return JSON.stringify({refreshed: true, method: 'overlay'}); }
        var mask = document.querySelector('.qrcode .mask, .login_box .mask');
        if (mask) { mask.click(); return JSON.stringify({refreshed: true, method: 'mask'}); }
        return JSON.stringify({refreshed: false});
      } catch(e) {
        return JSON.stringify({error: e.message});
      }
    })()
    """

    static let contactsScript: String = """
    (function() {
      try {
        return JSON.stringify(WechatyBro.contactList());
      } catch(e) {
        return JSON.stringify({error: e.message});
      }
    })()
    """

    static func sendScript(to: String, content: String, watermark: Bool = false) -> String {
        let escapedTo = to.replacingOccurrences(of: "'", with: "\\'")
        let escapedContent = content.replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
          try {
            var result = WechatyBro.send('\(escapedTo)', '\(escapedContent)', \(watermark));
            return JSON.stringify({ok: result});
          } catch(e) {
            return JSON.stringify({error: e.message});
          }
        })()
        """
    }

    static func atScript(userId: String, roomId: String? = nil) -> String {
        let escapedUser = userId.replacingOccurrences(of: "'", with: "\\'")
        let roomArg = roomId.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" } ?? "undefined"
        return """
        (function() {
          try {
            return WechatyBro.at('\(escapedUser)', \(roomArg));
          } catch(e) {
            return '@\(escapedUser)\\u2005';
          }
        })()
        """
    }

    static let isFromAIScript: String = """
    (function() {
      return !!(window.WechatyBro && window.WechatyBro.isFromAI);
    })()
    """

    static func sendUntrackedScript(to: String, content: String) -> String {
        let escapedTo = to.replacingOccurrences(of: "'", with: "\\'")
        let escapedContent = content.replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
          try {
            var injector = angular.element(document).injector();
            var chatFactory = injector.get('chatFactory');
            var confFactory = injector.get('confFactory');
            var userName = WechatyBro._resolveUserName('\(escapedTo)') || '\(escapedTo)';
            var m = chatFactory.createMessage({
              ToUserName: userName,
              Content: '\(escapedContent)',
              MsgType: confFactory.MSGTYPE_TEXT
            });
            chatFactory.appendMessage(m);
            chatFactory.sendMessage(m);
            return JSON.stringify({ok: true, msgId: m.MsgId, to: userName});
          } catch(e) {
            return JSON.stringify({ok: false, error: e.message});
          }
        })()
        """
    }

    static func uploadParamsScript(to: String) -> String {
        let escapedTo = to.replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
          try {
            var params = WechatyBro.getUploadParams('\(escapedTo)');
            return JSON.stringify(params);
          } catch(e) {
            return JSON.stringify({error: e.message});
          }
        })()
        """
    }

    static func roomMembersScript(roomId: String) -> String {
        let escapedRoom = roomId.replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
          try {
            return JSON.stringify(WechatyBro.getRoomMembers('\(escapedRoom)'));
          } catch(e) {
            return JSON.stringify([]);
          }
        })()
        """
    }

    static func sendImageScript(to: String, mediaId: String) -> String {
        let escapedTo = to.replacingOccurrences(of: "'", with: "\\'")
        let escapedId = mediaId.replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
          try {
            var result = WechatyBro.sendImageWithMediaId('\(escapedTo)', '\(escapedId)');
            return JSON.stringify({ok: result});
          } catch(e) {
            return JSON.stringify({error: e.message});
          }
        })()
        """
    }

    // MARK: - Init

    public override init() {
        let config = WKWebViewConfiguration()
        config.processPool = WKProcessPool()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        #endif
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let bridgeScript = WKUserScript(
            source: Self.bridgeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(bridgeScript)

        self.webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
            configuration: config
        )
        super.init()

        config.userContentController.add(self, name: "wechatEvent")

        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.navigationDelegate = self
    }

    // MARK: - Public API

    public func start() {
        guard state == .disconnected || state == .dead else { return }

        setState(.loading)
        bridgeInjected = false
        qrCodeURL = nil
        loggedInUser = nil

        var request = URLRequest(url: URL(string: Self.wechatURL)!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        webView.load(request)
        startBridgeRetry()
    }

    public func destroy() {
        stopBridgeRetry()
        stopHeartbeatMonitor()
        qrRefreshTimer?.invalidate()
        qrRefreshTimer = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "wechatEvent")
        bridgeInjected = false
        qrCodeURL = nil
        loggedInUser = nil
        contacts = []
        messageCount = 0
        setState(.disconnected)
    }

    public func restart() {
        destroy()
        start()
    }

    public func sendMessage(to: String, content: String, watermark: Bool = false) async -> Bool {
        guard state == .ready else { return false }
        let script = Self.sendScript(to: to, content: content, watermark: watermark)
        do {
            let result = try await webView.evaluateJavaScript(script)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool {
                return ok
            }
        } catch {}
        return false
    }

    public func sendUntracked(to: String, content: String) async -> (ok: Bool, msgId: String?) {
        guard state == .ready else { return (false, nil) }
        let script = Self.sendUntrackedScript(to: to, content: content)
        do {
            let result = try await webView.evaluateJavaScript(script)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (json["ok"] as? Bool ?? false, json["msgId"] as? String)
            }
        } catch {}
        return (false, nil)
    }

    public func getContacts() async -> [WeChatContact] {
        guard state == .ready else { return [] }
        do {
            let result = try await webView.evaluateJavaScript(Self.contactsScript)
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
        } catch {}
        return []
    }

    public func getRoomMembers(roomId: String) async -> [WeChatRoomMember] {
        guard state == .ready else { return [] }
        do {
            let result = try await webView.evaluateJavaScript(Self.roomMembersScript(roomId: roomId))
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return json.compactMap { dict -> WeChatRoomMember? in
                    guard let id = dict["id"] as? String,
                          let name = dict["name"] as? String else { return nil }
                    return WeChatRoomMember(id: id, name: name, userName: dict["UserName"] as? String ?? id)
                }
            }
        } catch {}
        return []
    }

    // MARK: - QR Code Generation

    #if os(iOS)
    public static func generateQRCode(from string: String, size: CGFloat = 200) -> UIImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scaleX = size / ciImage.extent.size.width
        let scaleY = size / ciImage.extent.size.height
        let transformedImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformedImage, from: transformedImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif

    // MARK: - State Machine

    private func setState(_ newState: WeChatChannelState) {
        print("[WeChatBridge] state: \(state.rawValue) → \(newState.rawValue)")
        state = newState
        onStateChange?(newState)
    }

    // MARK: - Bridge Injection

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
                    print("[WeChatBridge] Bridge injection failed after \(Self.bridgeMaxRetries) retries")
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

    private func tryInjectBridge() async {
        guard !bridgeInjected else { return }
        do {
            let result = try await webView.evaluateJavaScript(Self.angularCheckScript)
            guard let ready = result as? Bool, ready else { return }
        } catch { return }

        do {
            let result = try await webView.evaluateJavaScript(Self.injectionScript)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["code"] as? Int,
               code == 200 || code == 304 {
                bridgeInjected = true
                stopBridgeRetry()
                startHeartbeatMonitor()

                let loggedIn = try? await webView.evaluateJavaScript(Self.loginCheckScript) as? Bool
                if loggedIn == true {
                    setState(.ready)
                    Task { _ = await getContacts() }
                }
            }
        } catch {}
    }

    // MARK: - Heartbeat Monitor

    private func startHeartbeatMonitor() {
        stopHeartbeatMonitor()
        heartbeatDeadline = Date().addingTimeInterval(Self.heartbeatTimeout)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let deadline = self.heartbeatDeadline, Date() > deadline {
                    self.setState(.dead)
                    self.stopHeartbeatMonitor()
                }
            }
        }
    }

    private func stopHeartbeatMonitor() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - QR Refresh

    private func scheduleQRRefresh() {
        qrRefreshTimer?.invalidate()
        qrRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.qrRefreshTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshQRCode()
            }
        }
    }

    private func refreshQRCode() async {
        guard state == .qrReady || state == .loggingIn else { return }
        do {
            let result = try await webView.evaluateJavaScript(Self.qrRefreshScript)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let refreshed = json["refreshed"] as? Bool, refreshed {
                qrCodeURL = nil
                setState(.loading)
                return
            }
        } catch {}

        // Fallback: full page reload
        qrCodeURL = nil
        bridgeInjected = false
        setState(.loading)
        var request = URLRequest(url: URL(string: Self.wechatURL)!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        webView.load(request)
        startBridgeRetry()
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: WeChatBridgeEvent) {
        switch event {
        case .scan(let code, let url):
            qrCodeURL = url
            if code == 201 {
                setState(.loggingIn)
            } else if state != .qrReady {
                setState(.qrReady)
                scheduleQRRefresh()
            }

        case .login(let user):
            loggedInUser = user
            setState(.ready)
            qrRefreshTimer?.invalidate()
            qrRefreshTimer = nil
            Task { _ = await getContacts() }

        case .logout:
            loggedInUser = nil
            contacts = []
            setState(.dead)
            stopHeartbeatMonitor()

        case .message(let msg):
            messageCount += 1
            onMessage?(msg)

        case .heartbeat:
            heartbeatDeadline = Date().addingTimeInterval(Self.heartbeatTimeout)

        case .contacts(let count):
            _ = count

        case .contactsReady:
            Task { _ = await getContacts() }

        case .error(let msg):
            print("[WeChatBridge] JS error: \(msg)")
        }
    }
}

// MARK: - WKNavigationDelegate

extension WeChatBridge: WKNavigationDelegate {
    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            if !bridgeInjected {
                await tryInjectBridge()
                if !bridgeInjected { startBridgeRetry() }
            }
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

    public nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            bridgeInjected = false
            stopBridgeRetry()
            stopHeartbeatMonitor()
            qrRefreshTimer?.invalidate()
            qrRefreshTimer = nil
            setState(.dead)
        }
    }
}

// MARK: - WKScriptMessageHandler

extension WeChatBridge: WKScriptMessageHandler {
    public nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "wechatEvent",
              let body = message.body as? [String: Any],
              let eventName = body["event"] as? String else { return }

        let dict: [String: Any] = ["type": eventName, "data": body["data"] as Any]

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let event = WeChatBridgeEvent.parse(dict) {
                self.handleEvent(event)
            }
        }
    }
}
