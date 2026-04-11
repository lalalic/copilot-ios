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
    private var cachedEmojis: [String]?

    private static let wechatURL = "https://wx.qq.com/"

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

    /// wechat-bro.js source, loaded from bundle.
    static let injectScript: String = wechatBroSource

    /// Evaluate a JS expression on wechat-bro, wrapping result in JSON.
    private func eval(_ js: String) async -> [String: Any]? {
        let wrapped = """
        (function() {
          try { return JSON.stringify(\(js)); }
          catch(e) { return JSON.stringify({error: e.message}); }
        })()
        """
        guard let str = try? await webView.evaluateJavaScript(wrapped) as? String,
              let data = str.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Evaluate a JS expression returning an array.
    private func evalArray(_ js: String) async -> [[String: Any]] {
        let wrapped = """
        (function() {
          try { return JSON.stringify(\(js)); }
          catch(e) { return JSON.stringify([]); }
        })()
        """
        guard let str = try? await webView.evaluateJavaScript(wrapped) as? String,
              let data = str.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    // MARK: - Init

    public override init() {
        let config = SharedWebKitEnvironment.shared.createConfiguration()

        let bridgeScript = WKUserScript(
            source: Self.bridgeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(bridgeScript)

        // Enable pinch-to-zoom by overriding viewport meta tag
        let zoomScript = WKUserScript(
            source: """
            var meta = document.querySelector('meta[name=viewport]');
            if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; document.head.appendChild(meta); }
            meta.content = 'width=device-width, initial-scale=0.5, minimum-scale=0.25, maximum-scale=5.0, user-scalable=yes';
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(zoomScript)

        self.webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
            configuration: config
        )
        super.init()

        config.userContentController.add(self, name: "wechatEvent")

        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.navigationDelegate = self
        #if os(iOS)
        webView.scrollView.minimumZoomScale = 0.25
        webView.scrollView.maximumZoomScale = 5.0
        webView.scrollView.bouncesZoom = true
        #endif

        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
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

        // Also start Angular polling as fallback (didFinish may not fire for SPAs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.bridgeInjected else { return }
            self.waitForAngularAndInject()
        }
    }

    public func destroy() {
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

    /// Reload the current page and reinject the bridge.
    public func reload() {
        bridgeInjected = false
        webView.reload()
    }

    private static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    public func sendMessage(to: String, content: String, watermark: Bool = false) async -> Bool {
        guard state == .ready else { return false }
        let t = Self.jsEscape(to), c = Self.jsEscape(content)
        let json = await eval("WechatyBro.send('\(t)', '\(c)', \(watermark))")
        return json?["ok"] as? Bool ?? false
    }

    public func sendUntracked(to: String, content: String) async -> (ok: Bool, msgId: String?) {
        guard state == .ready else { return (false, nil) }
        let t = Self.jsEscape(to), c = Self.jsEscape(content)
        let js = """
        (function() {
          var injector = angular.element(document).injector();
          var cf = injector.get('chatFactory'), conf = injector.get('confFactory');
          var userName = WechatyBro._resolveUserName('\(t)') || '\(t)';
          var m = cf.createMessage({ToUserName: userName, Content: '\(c)', MsgType: conf.MSGTYPE_TEXT});
          cf.appendMessage(m); cf.sendMessage(m);
          return {ok: true, msgId: m.MsgId, to: userName};
        })()
        """
        let json = await eval(js)
        return (json?["ok"] as? Bool ?? false, json?["msgId"] as? String)
    }

    public func getContacts() async -> [WeChatContact] {
        guard state == .ready else { return [] }
        let raw = await evalArray("WechatyBro.contactList()")
        let parsed = raw.compactMap { dict -> WeChatContact? in
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

    public func getRoomMembers(roomId: String) async -> [WeChatRoomMember] {
        guard state == .ready else { return [] }
        let r = Self.jsEscape(roomId)
        let raw = await evalArray("WechatyBro.getRoomMembers('\(r)')")
        return raw.compactMap { dict -> WeChatRoomMember? in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            return WeChatRoomMember(id: id, name: name, userName: dict["UserName"] as? String ?? id)
        }
    }

    public func sendImage(to: String, mediaId: String) async -> Bool {
        guard state == .ready else { return false }
        let t = Self.jsEscape(to), m = Self.jsEscape(mediaId)
        let json = await eval("WechatyBro.sendImageWithMediaId('\(t)', '\(m)')")
        return json?["ok"] as? Bool ?? false
    }

    public func getUploadParams(to: String) async -> [String: Any]? {
        guard state == .ready else { return nil }
        let t = Self.jsEscape(to)
        return await eval("WechatyBro.getUploadParams('\(t)')")
    }

    /// Build an @mention string for room replies (e.g. "@Alice\u{2005}").
    public func buildAtMention(userId: String, roomId: String) async -> String {
        guard state == .ready else { return "" }
        let u = Self.jsEscape(userId), r = Self.jsEscape(roomId)
        let json = await eval("({result: WechatyBro.at('\(u)', '\(r)')})")
        return json?["result"] as? String ?? ""
    }

    /// Get supported WeChat emoji shortcodes (cached, 209 codes).
    public func getSupportedEmojis() async -> [String] {
        if let cached = cachedEmojis { return cached }
        guard state == .ready else { return [] }
        let raw = await evalArray("WechatyBro.getSupportedEmojis().map(e => ({code: e}))")
        let codes = raw.compactMap { $0["code"] as? String }
        cachedEmojis = codes
        return codes
    }

    /// Simulate an incoming message for testing (bypasses real WeChat).
    public func simulateMessage(from: String, content: String, sender: String? = nil, msgType: Int = 1) async {
        guard state == .ready else { return }
        let f = Self.jsEscape(from), c = Self.jsEscape(content)
        let senderArg = sender.map { "'\(Self.jsEscape($0))'" } ?? "null"
        _ = await eval("WechatyBro.simulateMessage('\(f)', '\(c)', \(senderArg), \(msgType))")
    }

    /// Get a contact's avatar as base64 data URI.
    public func getContactImage(id: String) async -> String? {
        guard state == .ready else { return nil }
        let i = Self.jsEscape(id)
        let json = await eval("({result: WechatyBro.getContactImage('\(i)')})")
        return json?["result"] as? String
    }

    /// Send a file attachment using a pre-uploaded media ID.
    public func sendFile(to: String, mediaId: String, filename: String, fileSize: Int) async -> Bool {
        guard state == .ready else { return false }
        let t = Self.jsEscape(to), m = Self.jsEscape(mediaId), f = Self.jsEscape(filename)
        let json = await eval("WechatyBro.sendFileWithMediaId('\(t)', '\(m)', '\(f)', \(fileSize))")
        return json?["ok"] as? Bool ?? false
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

    private func waitForAngularAndInject() {
        webView.evaluateJavaScript("""
            (typeof angular !== 'undefined' && angular.element && angular.element(document).injector()) ? true : false
        """) { [weak self] result, _ in
            guard let self else { return }
            if result as? Bool == true {
                Task { @MainActor in await self.injectBridge() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.waitForAngularAndInject()
                }
            }
        }
    }

    private func injectBridge() async {
        guard !bridgeInjected else { return }
        do {
            try await webView.evaluateJavaScript(Self.injectScript)
        } catch { return }
        // WechatyBro.init() returns a JS object — stringify to avoid bridge error
        do {
            _ = try await webView.evaluateJavaScript("JSON.stringify(WechatyBro.init())")
            bridgeInjected = true
        } catch {}
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: WeChatBridgeEvent) {
        switch event {
        case .scan(let code, let url):
            if code == 200 || code == 201 {
                qrCodeURL = nil
                setState(.loggingIn)
            } else {
                qrCodeURL = url
                if state != .qrReady {
                    setState(.qrReady)
                }
            }

        case .login(let user):
            loggedInUser = user
            qrCodeURL = nil
            setState(.ready)
            Task { _ = await getContacts() }

        case .logout:
            loggedInUser = nil
            contacts = []
            setState(.dead)

        case .message(let msg):
            messageCount += 1
            onMessage?(msg)

        case .heartbeat:
            break // JS bridge manages its own heartbeat

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
    public nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            bridgeInjected = false
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            bridgeInjected = false
            // Fallback: start injection polling after page commits (didFinish may not fire for SPAs)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.bridgeInjected else { return }
                self.waitForAngularAndInject()
            }
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            if !bridgeInjected { waitForAngularAndInject() }
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
