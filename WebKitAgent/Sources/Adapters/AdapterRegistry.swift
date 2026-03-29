import Foundation

/// Manages discovery and lookup of site adapters.
@MainActor
public final class AdapterRegistry {

    /// Key format: "site/name"
    private var adapters: [String: YAMLAdapter] = [:]

    public init() {}

    // MARK: - Registration

    /// Register an adapter from a YAML string.
    public func register(yaml: String) throws {
        let adapter = try YAMLAdapter.parse(yaml)
        let key = "\(adapter.site)/\(adapter.name)"
        adapters[key] = adapter
    }

    /// Register a pre-parsed adapter.
    public func register(adapter: YAMLAdapter) {
        let key = "\(adapter.site)/\(adapter.name)"
        adapters[key] = adapter
    }

    // MARK: - Lookup

    /// Find an adapter by site and action name.
    public func find(site: String, action: String) -> YAMLAdapter? {
        adapters["\(site)/\(action)"]
    }

    /// Number of registered adapters.
    public var adapterCount: Int {
        adapters.count
    }

    // MARK: - List

    /// List all registered adapters.
    public func listAll() -> [YAMLAdapter] {
        Array(adapters.values).sorted(by: { "\($0.site)/\($0.name)" < "\($1.site)/\($1.name)" })
    }

    /// List adapters for a specific site.
    public func listForSite(_ site: String) -> [YAMLAdapter] {
        adapters.values.filter { $0.site == site }
            .sorted(by: { $0.name < $1.name })
    }

    /// Formatted listing of all adapters for display.
    public func listFormatted() -> String {
        if adapters.isEmpty {
            return "No site adapters registered."
        }

        let grouped = Dictionary(grouping: adapters.values, by: { $0.site })
        var lines: [String] = ["Available site adapters:"]

        for site in grouped.keys.sorted() {
            lines.append("\n  \(site):")
            for adapter in grouped[site]!.sorted(by: { $0.name < $1.name }) {
                let auth = adapter.auth == .none ? "" : " [auth required]"
                let browser = adapter.requiresBrowser ? " [browser]" : ""
                lines.append("    - \(adapter.name): \(adapter.adapterDescription)\(auth)\(browser)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Load from Directory

    /// Load all `.yaml` adapter files from a directory.
    public func loadFromDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: nil)
        for fileURL in contents where fileURL.pathExtension == "yaml" {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            try register(yaml: text)
        }
    }

    /// Load bundled adapters from the module's bundle.
    public func loadBundledAdapters() {
        // Load from Bundle.module if adapters are included as resources
        // For now, register the built-in HackerNews adapter
        let hnTop = """
        site: hackernews
        name: top
        description: Get top Hacker News stories
        auth: none
        requiresBrowser: false
        args:
          limit:
            type: int
            default: 20
            description: Number of stories to return
        pipeline:
          - fetch: https://hacker-news.firebaseio.com/v0/topstories.json
          - slice: { to: 30 }
          - fetchEach: "https://hacker-news.firebaseio.com/v0/item/${{ item }}.json"
          - filter: "item.title != nil"
          - map: { rank: "${{ index + 1 }}", title: "${{ item.title }}", score: "${{ item.score }}", author: "${{ item.by }}", url: "${{ item.url }}" }
          - slice: { to: 20 }
        """

        let hnNew = """
        site: hackernews
        name: new
        description: Get newest Hacker News stories
        auth: none
        requiresBrowser: false
        args:
          limit:
            type: int
            default: 20
            description: Number of stories to return
        pipeline:
          - fetch: https://hacker-news.firebaseio.com/v0/newstories.json
          - slice: { to: 30 }
          - fetchEach: "https://hacker-news.firebaseio.com/v0/item/${{ item }}.json"
          - filter: "item.title != nil"
          - map: { rank: "${{ index + 1 }}", title: "${{ item.title }}", score: "${{ item.score }}", author: "${{ item.by }}", url: "${{ item.url }}" }
          - slice: { to: 20 }
        """

        let hnBest = """
        site: hackernews
        name: best
        description: Get best Hacker News stories
        auth: none
        requiresBrowser: false
        args:
          limit:
            type: int
            default: 20
            description: Number of stories to return
        pipeline:
          - fetch: https://hacker-news.firebaseio.com/v0/beststories.json
          - slice: { to: 30 }
          - fetchEach: "https://hacker-news.firebaseio.com/v0/item/${{ item }}.json"
          - filter: "item.title != nil"
          - map: { rank: "${{ index + 1 }}", title: "${{ item.title }}", score: "${{ item.score }}", author: "${{ item.by }}", url: "${{ item.url }}" }
          - slice: { to: 20 }
        """

        for yaml in [hnTop, hnNew, hnBest] {
            try? register(yaml: yaml)
        }

        // WeChat Web adapters (browser-based, hook into AngularJS)
        registerWeChatAdapters()
    }

    // MARK: - WeChat Adapters

    private func registerWeChatAdapters() {
        // wechat/login — navigate to wx.qq.com and get QR code URL
        let wxLogin = """
        site: wechat
        name: login
        description: Get WeChat Web login QR code URL
        auth: none
        requiresBrowser: true
        preNavigate: https://wx.qq.com
        waitSeconds: 5
        script: |
          (() => {
            // Check if already logged in
            if (window.MMCgi && window.MMCgi.isLogin) {
              return JSON.stringify([{status: "logged_in", message: "Already logged in to WeChat Web"}]);
            }
            // Check if Angular is ready with login scope
            if (typeof angular !== 'undefined' && angular.element) {
              try {
                const loginScope = angular.element('[ng-controller="loginController"]').scope();
                if (loginScope && loginScope.qrcodeUrl) {
                  return JSON.stringify([{
                    status: "qr_ready",
                    code: loginScope.code,
                    qrcodeUrl: loginScope.qrcodeUrl,
                    message: "Scan QR code with WeChat mobile app"
                  }]);
                }
              } catch (e) {}
            }
            // Try to find QR code image directly
            const qrImg = document.querySelector('.qrcode img') || document.querySelector('img[src*="qrcode"]');
            if (qrImg) {
              return JSON.stringify([{
                status: "qr_image",
                src: qrImg.src,
                message: "QR code image found. Scan with WeChat mobile app."
              }]);
            }
            return JSON.stringify([{status: "loading", message: "WeChat Web is still loading..."}]);
          })()
        """

        // wechat/status — check login status
        let wxStatus = """
        site: wechat
        name: status
        description: Check WeChat Web login status
        auth: none
        requiresBrowser: true
        script: |
          (() => {
            if (typeof angular === 'undefined' || !angular.element) {
              return JSON.stringify([{status: "not_loaded", angularReady: false}]);
            }
            try {
              const injector = angular.element(document).injector();
              const loginScope = angular.element('[ng-controller="loginController"]').scope();
              const isLoggedIn = !!(window.MMCgi && window.MMCgi.isLogin);
              return JSON.stringify([{
                status: isLoggedIn ? "logged_in" : "not_logged_in",
                loginCode: loginScope ? loginScope.code : null,
                angularReady: !!injector,
                url: window.location.href
              }]);
            } catch (e) {
              return JSON.stringify([{status: "error", message: e.message}]);
            }
          })()
        """

        // wechat/contacts — get all contacts (requires logged-in state)
        let wxContacts = """
        site: wechat
        name: contacts
        description: Get WeChat contact list (must be logged in)
        auth: cookie
        domain: wx.qq.com
        requiresBrowser: true
        args:
          limit:
            type: int
            default: 50
            description: Maximum number of contacts
        script: |
          (() => {
            if (typeof angular === 'undefined') {
              return JSON.stringify([{error: "Not logged in. Use wechat/login first."}]);
            }
            try {
              const injector = angular.element(document).injector();
              if (!injector) return JSON.stringify([{error: "Angular not ready"}]);
              const contactFactory = injector.get('contactFactory');
              const contacts = contactFactory.getAllFriendContact();
              return JSON.stringify(contacts.slice(0, 50).map((c, i) => ({
                rank: i + 1,
                name: c.NickName || c.RemarkName || 'Unknown',
                remark: c.RemarkName || '',
                username: c.UserName,
                sex: c.Sex === 1 ? 'M' : c.Sex === 2 ? 'F' : '?'
              })));
            } catch (e) {
              return JSON.stringify([{error: e.message}]);
            }
          })()
        """

        // wechat/send — send a message (requires logged-in state)
        let wxSend = """
        site: wechat
        name: send
        description: Send a WeChat message (must be logged in)
        auth: cookie
        domain: wx.qq.com
        requiresBrowser: true
        args:
          to:
            type: string
            description: Recipient UserName
          message:
            type: string
            description: Message text to send
        script: |
          (() => {
            if (typeof angular === 'undefined') {
              return JSON.stringify([{error: "Not logged in"}]);
            }
            try {
              const injector = angular.element(document).injector();
              const chatFactory = injector.get('chatFactory');
              const confFactory = injector.get('confFactory');
              // Note: to and message are injected by the adapter args system
              // This script runs in the browser context and needs the args passed in
              return JSON.stringify([{status: "ready", message: "Use evaluate command to send: chatFactory.sendMessage(...)"}]);
            } catch (e) {
              return JSON.stringify([{error: e.message}]);
            }
          })()
        """

        for yaml in [wxLogin, wxStatus, wxContacts, wxSend] {
            try? register(yaml: yaml)
        }
    }
}
