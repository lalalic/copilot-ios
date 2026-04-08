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

        // Xiaohongshu adapters (browser-based)
        registerXiaohongshuAdapters()

        // Convertio adapter (file conversion)
        registerConvertioAdapters()

        // GitHub adapters (browser-based)
        registerGitHubAdapters()
    }

    // MARK: - GitHub Adapters

    private func registerGitHubAdapters() {
        // github/trending — get trending repos
        let ghTrending = """
        site: github
        name: trending
        description: Get trending GitHub repositories
        auth: none
        requiresBrowser: true
        preNavigate: https://github.com/trending
        waitSeconds: 3
        args:
          language:
            type: string
            default:
            description: Filter by language (e.g. swift, python, javascript)
          since:
            type: string
            default: daily
            description: Time range (daily, weekly, monthly)
        script: |
          (() => {
            const rows = document.querySelectorAll('article.Box-row');
            const results = [];
            rows.forEach((row, i) => {
              const nameEl = row.querySelector('h2 a');
              const descEl = row.querySelector('p');
              const langEl = row.querySelector('[itemprop="programmingLanguage"]');
              const starsEl = row.querySelector('a[href$="/stargazers"]');
              const forksEl = row.querySelector('a[href$="/forks"]');
              const todayEl = row.querySelector('.float-sm-right, span.d-inline-block.float-sm-right');
              results.push({
                rank: i + 1,
                name: nameEl ? nameEl.textContent.trim().replace(/\\s+/g, '') : '',
                description: descEl ? descEl.textContent.trim() : '',
                language: langEl ? langEl.textContent.trim() : '',
                stars: starsEl ? starsEl.textContent.trim() : '',
                forks: forksEl ? forksEl.textContent.trim() : '',
                todayStars: todayEl ? todayEl.textContent.trim() : '',
                url: nameEl ? 'https://github.com' + nameEl.getAttribute('href') : ''
              });
            });
            return JSON.stringify(results);
          })()
        """

        // github/search — search repos
        let ghSearch = """
        site: github
        name: search
        description: Search GitHub repositories
        auth: none
        requiresBrowser: true
        args:
          query:
            type: string
            description: Search query
          sort:
            type: string
            default: stars
            description: Sort by (stars, forks, updated)
        script: |
          (() => {
            const query = __adapterArgs.query;
            const sort = __adapterArgs.sort || 'stars';
            if (!query) return JSON.stringify([{error: "query parameter is required"}]);
            window.location.href = 'https://github.com/search?q=' + encodeURIComponent(query) + '&type=repositories&s=' + sort + '&o=desc';
            return JSON.stringify([{status: "navigating", message: "Searching GitHub for: " + query}]);
          })()
        """

        for yaml in [ghTrending, ghSearch] {
            try? register(yaml: yaml)
        }
    }

    // MARK: - Convertio Adapters

    private func registerConvertioAdapters() {
        let convert = """
        site: convertio
        name: convert
        description: Convert a file to another format via convertio.co
        auth: none
        requiresBrowser: true
        preNavigate: https://convertio.co/
        waitSeconds: 3
        args:
          filePath:
            type: string
            description: Absolute path to the file to convert
          outputFormat:
            type: string
            default: txt
            description: Target format (e.g. txt, md, pdf, docx)
        script: |
          (() => {
            return JSON.stringify({status: "ready", message: "Convertio page loaded. Use upload and click commands to complete conversion."});
          })()
        """
        try? register(yaml: convert)
    }

    // MARK: - Xiaohongshu Adapters

    private func registerXiaohongshuAdapters() {
        // xiaohongshu/explore — get explore/trending notes
        let xhsExplore = """
        site: xiaohongshu
        name: explore
        description: Get trending notes from Xiaohongshu explore page
        auth: cookie
        domain: xiaohongshu.com
        requiresBrowser: true
        preNavigate: https://www.xiaohongshu.com/explore
        waitSeconds: 5
        args:
          limit:
            type: int
            default: 20
            description: Number of notes to return
        script: |
          (() => {
            const limit = parseInt(__adapterArgs.limit) || 20;
            const notes = [];
            const cards = document.querySelectorAll('[class*="note-item"], .feeds-page .note-item, section.note-item, a[href*="/explore/"]');
            cards.forEach((card, i) => {
              if (i >= limit) return;
              const titleEl = card.querySelector('[class*="title"], .title, span.title');
              const authorEl = card.querySelector('[class*="author"], .author, span.name');
              const likeEl = card.querySelector('[class*="like-wrapper"], .like-wrapper, span.count');
              const imgEl = card.querySelector('img');
              const linkEl = card.closest('a') || card.querySelector('a');
              notes.push({
                rank: i + 1,
                title: titleEl ? titleEl.textContent.trim() : (card.textContent || '').trim().substring(0, 60),
                author: authorEl ? authorEl.textContent.trim() : '',
                likes: likeEl ? likeEl.textContent.trim() : '',
                image: imgEl ? imgEl.src : '',
                url: linkEl ? linkEl.href : ''
              });
            });
            if (notes.length === 0) {
              return JSON.stringify([{info: "No notes found. Page may need login or different DOM structure.", url: window.location.href}]);
            }
            return JSON.stringify(notes);
          })()
        """

        // xiaohongshu/search — search for notes
        let xhsSearch = """
        site: xiaohongshu
        name: search
        description: Search for notes on Xiaohongshu
        auth: cookie
        domain: xiaohongshu.com
        requiresBrowser: true
        args:
          query:
            type: string
            description: Search query
          limit:
            type: int
            default: 20
            description: Number of results to return
        script: |
          (() => {
            const query = __adapterArgs.query;
            if (!query) return JSON.stringify([{error: "query parameter is required"}]);
            const encoded = encodeURIComponent(query);
            window.location.href = 'https://www.xiaohongshu.com/search_result?keyword=' + encoded + '&type=1';
            return JSON.stringify([{status: "navigating", message: "Navigating to search results for: " + query + ". Run this command again in a few seconds to get results."}]);
          })()
        """

        // xiaohongshu/profile — get current user profile info
        let xhsProfile = """
        site: xiaohongshu
        name: profile
        description: Get current logged-in user profile
        auth: cookie
        domain: xiaohongshu.com
        requiresBrowser: true
        preNavigate: https://www.xiaohongshu.com/user/profile
        waitSeconds: 3
        script: |
          (() => {
            const nameEl = document.querySelector('[class*="user-name"], .user-name, .name');
            const idEl = document.querySelector('[class*="user-id"], .user-redId, .red-id');
            const bioEl = document.querySelector('[class*="user-desc"], .desc');
            const followingEl = document.querySelector('[class*="following"] [class*="count"], .count:first-child');
            const fansEl = document.querySelector('[class*="fans"] [class*="count"]');
            const avatarEl = document.querySelector('[class*="avatar"] img, .avatar img');
            if (!nameEl) {
              return JSON.stringify([{error: "Profile not found. You may not be logged in.", url: window.location.href}]);
            }
            return JSON.stringify([{
              name: nameEl ? nameEl.textContent.trim() : '',
              redId: idEl ? idEl.textContent.trim() : '',
              bio: bioEl ? bioEl.textContent.trim() : '',
              avatar: avatarEl ? avatarEl.src : '',
              url: window.location.href
            }]);
          })()
        """

        // xiaohongshu/post — create a new note (text only for now)
        let xhsPost = """
        site: xiaohongshu
        name: post
        description: Navigate to Xiaohongshu note creation page
        auth: cookie
        domain: xiaohongshu.com
        requiresBrowser: true
        preNavigate: https://creator.xiaohongshu.com/publish/publish
        waitSeconds: 3
        script: |
          (() => {
            return JSON.stringify([{
              status: "ready",
              message: "Xiaohongshu creator page loaded. Use snapshot + click + type to fill in the note.",
              url: window.location.href
            }]);
          })()
        """

        for yaml in [xhsExplore, xhsSearch, xhsProfile, xhsPost] {
            try? register(yaml: yaml)
        }
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
        preNavigate: https://wx.qq.com
        waitSeconds: 3
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
              const limit = parseInt(__adapterArgs.limit) || 50;
              return JSON.stringify(contacts.slice(0, limit).map((c, i) => ({
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
            description: Recipient name or UserName
          message:
            type: string
            description: Message text to send
        script: |
          (() => {
            if (typeof angular === 'undefined') {
              return JSON.stringify([{error: "Not logged in. Use wechat/login first."}]);
            }
            const to = __adapterArgs.to;
            const message = __adapterArgs.message;
            if (!to || !message) {
              return JSON.stringify([{error: "Both 'to' and 'message' parameters are required."}]);
            }
            try {
              const injector = angular.element(document).injector();
              const contactFactory = injector.get('contactFactory');
              const chatFactory = injector.get('chatFactory');
              // Find contact by NickName or RemarkName or UserName
              const allContacts = contactFactory.getAllFriendContact();
              const contact = allContacts.find(c =>
                c.NickName === to || c.RemarkName === to || c.UserName === to
              );
              if (!contact) {
                return JSON.stringify([{error: "Contact not found: " + to}]);
              }
              // Send message via AngularJS chatFactory
              chatFactory.sendMessage(contact.UserName, message);
              return JSON.stringify([{
                status: "sent",
                to: contact.NickName || contact.RemarkName,
                userName: contact.UserName,
                message: message
              }]);
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
