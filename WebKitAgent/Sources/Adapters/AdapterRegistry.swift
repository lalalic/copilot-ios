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

        // Reddit adapters (JSON API)
        registerRedditAdapters()

        // ProductHunt adapters (browser-based)
        registerProductHuntAdapters()

        // WeChat Channels (视频号) adapters
        registerWeChatChannelsAdapters()

        // YouTube adapters (browser-based)
        registerYouTubeAdapters()

        // TikTok adapters (browser-based)
        registerTikTokAdapters()
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

    // MARK: - Reddit Adapters

    private func registerRedditAdapters() {
        let redditHot = """
        site: reddit
        name: hot
        description: Get hot posts from a subreddit or front page
        auth: none
        requiresBrowser: false
        args:
          subreddit:
            type: string
            default:
            description: Subreddit name (without r/). Leave empty for front page
          limit:
            type: int
            default: 20
            description: Number of posts to return
        pipeline:
          - fetch: "https://www.reddit.com/${{ args.subreddit ? 'r/' + args.subreddit + '/' : '' }}hot.json?limit=25&raw_json=1"
          - extract: "data.children"
          - extract: "data"
          - filter: "item.title != nil"
          - map: { rank: "${{ index + 1 }}", title: "${{ item.title }}", score: "${{ item.score }}", author: "${{ item.author }}", subreddit: "${{ item.subreddit_name_prefixed }}", comments: "${{ item.num_comments }}", url: "${{ item.url }}" }
          - slice: { to: 20 }
        """

        let redditTop = """
        site: reddit
        name: top
        description: Get top posts from a subreddit or front page
        auth: none
        requiresBrowser: false
        args:
          subreddit:
            type: string
            default:
            description: Subreddit name (without r/)
          time:
            type: string
            default: day
            description: Time period (hour, day, week, month, year, all)
          limit:
            type: int
            default: 20
            description: Number of posts
        pipeline:
          - fetch: "https://www.reddit.com/${{ args.subreddit ? 'r/' + args.subreddit + '/' : '' }}top.json?t=${{ args.time }}&limit=25&raw_json=1"
          - extract: "data.children"
          - extract: "data"
          - filter: "item.title != nil"
          - map: { rank: "${{ index + 1 }}", title: "${{ item.title }}", score: "${{ item.score }}", author: "${{ item.author }}", subreddit: "${{ item.subreddit_name_prefixed }}", comments: "${{ item.num_comments }}", url: "${{ item.url }}" }
          - slice: { to: 20 }
        """

        let redditSearch = """
        site: reddit
        name: search
        description: Search Reddit posts
        auth: none
        requiresBrowser: false
        args:
          query:
            type: string
            description: Search query
          subreddit:
            type: string
            default:
            description: Limit search to a subreddit
          sort:
            type: string
            default: relevance
            description: Sort by (relevance, hot, top, new, comments)
          limit:
            type: int
            default: 20
            description: Number of results
        pipeline:
          - fetch: "https://www.reddit.com/${{ args.subreddit ? 'r/' + args.subreddit + '/' : '' }}search.json?q=${{ args.query }}&sort=${{ args.sort }}&limit=25&raw_json=1"
          - extract: "data.children"
          - extract: "data"
          - filter: "item.title != nil"
          - map: { rank: "${{ index + 1 }}", title: "${{ item.title }}", score: "${{ item.score }}", author: "${{ item.author }}", subreddit: "${{ item.subreddit_name_prefixed }}", comments: "${{ item.num_comments }}", url: "${{ item.url }}" }
          - slice: { to: 20 }
        """

        for yaml in [redditHot, redditTop, redditSearch] {
            try? register(yaml: yaml)
        }
    }

    // MARK: - ProductHunt Adapters

    private func registerProductHuntAdapters() {
        let phToday = """
        site: producthunt
        name: today
        description: Get today's top products from Product Hunt
        auth: none
        requiresBrowser: true
        preNavigate: https://www.producthunt.com
        waitSeconds: 5
        args:
          limit:
            type: int
            default: 20
            description: Number of products to return
        script: |
          (() => {
            const limit = parseInt(__adapterArgs.limit) || 20;
            const items = document.querySelectorAll('[data-test="post-item"], [class*="styles_item"], div[class*="post"]');
            const results = [];
            items.forEach((item, i) => {
              if (i >= limit) return;
              const nameEl = item.querySelector('a[href*="/posts/"] strong, [data-test="post-name"], h3');
              const taglineEl = item.querySelector('[data-test="post-tagline"], [class*="tagline"], p');
              const votesEl = item.querySelector('[data-test="vote-button"] span, button[class*="vote"] span, [class*="voteCount"]');
              const linkEl = item.querySelector('a[href*="/posts/"]');
              const imgEl = item.querySelector('img');
              results.push({
                rank: i + 1,
                name: nameEl ? nameEl.textContent.trim() : '',
                tagline: taglineEl ? taglineEl.textContent.trim() : '',
                votes: votesEl ? votesEl.textContent.trim() : '',
                url: linkEl ? linkEl.href : '',
                thumbnail: imgEl ? imgEl.src : ''
              });
            });
            if (results.length === 0) {
              return JSON.stringify([{info: "No products found. Page structure may have changed.", url: window.location.href}]);
            }
            return JSON.stringify(results);
          })()
        """

        try? register(yaml: phToday)
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
        preNavigate: https://www.xiaohongshu.com/explore
        waitSeconds: 2
        script: |
          (() => {
            const nameEl = document.querySelector('[class*="user-name"], .user-name');
            if (nameEl) {
              const idEl = document.querySelector('[class*="user-redId"], .red-id');
              const bioEl = document.querySelector('[class*="user-desc"], .desc');
              const avatarEl = document.querySelector('[class*="avatar"] img');
              return JSON.stringify([{
                name: nameEl.textContent.trim(),
                redId: idEl ? idEl.textContent.replace('小红书号：','').trim() : '',
                bio: bioEl ? bioEl.textContent.trim() : '',
                avatar: avatarEl ? avatarEl.src : '',
                url: window.location.href
              }]);
            }
            const profileLink = document.querySelector('a[href*="/user/profile/"]');
            if (!profileLink) {
              return JSON.stringify([{error: "Not logged in.", url: window.location.href}]);
            }
            const href = profileLink.getAttribute('href');
            const userId = href.match(/\\/user\\/profile\\/([a-f0-9]+)/)?.[1];
            if (!userId) {
              return JSON.stringify([{error: "Could not extract user ID.", url: window.location.href}]);
            }
            return JSON.stringify([{_navigateTo: "https://www.xiaohongshu.com/user/profile/" + userId}]);
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

    // MARK: - WeChat Channels (视频号) Adapters

    private func registerWeChatChannelsAdapters() {
        // wechat-channels/profile — get channel profile info
        let chProfile = """
        site: wechat-channels
        name: profile
        description: Get WeChat Channels (视频号) profile info
        auth: cookie
        domain: channels.weixin.qq.com
        requiresBrowser: true
        preNavigate: https://channels.weixin.qq.com/platform
        waitSeconds: 5
        script: |
          (() => {
            const getText = (sel) => {
              const el = document.querySelector(sel);
              if (el) return el.textContent.trim();
              const wa = document.querySelector('wujie-app');
              if (wa && wa.shadowRoot) {
                const inner = wa.shadowRoot.querySelector(sel);
                if (inner) return inner.textContent.trim();
              }
              return '';
            };
            const name = getText('.finder-nickname, .account-name, .nick-name');
            const id = getText('.finder-id, .account-id');
            if (!name) {
              return JSON.stringify([{error: "Profile not found. You may not be logged in.", url: window.location.href}]);
            }
            return JSON.stringify([{
              platform: "wechat-channels",
              name: name,
              channelId: id,
              url: window.location.href
            }]);
          })()
        """

        // wechat-channels/trending — get dashboard metrics and trending info
        let chTrending = """
        site: wechat-channels
        name: trending
        description: Get WeChat Channels dashboard metrics
        auth: cookie
        domain: channels.weixin.qq.com
        requiresBrowser: true
        preNavigate: https://channels.weixin.qq.com/platform
        waitSeconds: 5
        script: |
          (() => {
            const getText = (sel) => {
              const el = document.querySelector(sel);
              if (el) return el.textContent.trim();
              const wa = document.querySelector('wujie-app');
              if (wa && wa.shadowRoot) {
                const inner = wa.shadowRoot.querySelector(sel);
                if (inner) return inner.textContent.trim();
              }
              return '';
            };
            const cards = document.querySelectorAll('.data-card, .overview-card, [class*="data-item"]');
            const metrics = [];
            cards.forEach((card) => {
              const label = card.querySelector('.label, .title, .name');
              const value = card.querySelector('.value, .count, .num');
              if (label && value) {
                metrics.push({
                  metric: label.textContent.trim(),
                  value: value.textContent.trim()
                });
              }
            });
            return JSON.stringify(metrics.length > 0 ? metrics : [{info: "Navigate to dashboard to see metrics", url: window.location.href}]);
          })()
        """

        // wechat-channels/post — navigate to create post page
        let chPost = """
        site: wechat-channels
        name: post
        description: Navigate to WeChat Channels video upload page
        auth: cookie
        domain: channels.weixin.qq.com
        requiresBrowser: true
        preNavigate: https://channels.weixin.qq.com/platform/post/create
        waitSeconds: 5
        script: |
          (() => {
            return JSON.stringify([{
              status: "ready",
              message: "WeChat Channels upload page loaded. Use snapshot + upload + type to fill details.",
              url: window.location.href,
              tips: "Shadow DOM: use wujie-app >>> selector pattern if elements not found"
            }]);
          })()
        """

        for yaml in [chProfile, chTrending, chPost] {
            try? register(yaml: yaml)
        }
    }

    // MARK: - YouTube Adapters

    private func registerYouTubeAdapters() {
        // youtube/profile — get channel info from YouTube Studio
        let ytProfile = """
        site: youtube
        name: profile
        description: Get YouTube channel profile info from Studio
        auth: cookie
        domain: youtube.com
        requiresBrowser: true
        preNavigate: https://studio.youtube.com
        waitSeconds: 5
        script: |
          (() => {
            const nameEl = document.querySelector('.channel-name, [class*="channel-name"], .ytcd-channel-name');
            const subsEl = document.querySelector('[class*="subscriber-count"], .subscriber-count');
            const avatarEl = document.querySelector('.channel-thumbnail img, [class*="channel-avatar"] img');
            const channelUrl = window.location.href;
            const channelIdMatch = channelUrl.match(/channel\\/(UC[a-zA-Z0-9_-]+)/);
            return JSON.stringify([{
              platform: "youtube",
              name: nameEl ? nameEl.textContent.trim() : '',
              channelId: channelIdMatch ? channelIdMatch[1] : '',
              subscribers: subsEl ? subsEl.textContent.trim() : '',
              avatar: avatarEl ? avatarEl.src : '',
              studioUrl: window.location.href
            }]);
          })()
        """

        // youtube/trending — get trending videos
        let ytTrending = """
        site: youtube
        name: trending
        description: Get trending YouTube videos
        auth: none
        requiresBrowser: true
        preNavigate: https://www.youtube.com/feed/trending
        waitSeconds: 5
        args:
          limit:
            type: int
            default: 20
            description: Number of videos to return
        script: |
          (() => {
            const limit = parseInt(__adapterArgs.limit) || 20;
            const items = document.querySelectorAll('ytd-video-renderer, ytd-rich-item-renderer');
            const results = [];
            items.forEach((item, i) => {
              if (i >= limit) return;
              const titleEl = item.querySelector('#video-title');
              const channelEl = item.querySelector('#channel-name a, ytd-channel-name a');
              const viewsEl = item.querySelector('#metadata-line span');
              const linkEl = item.querySelector('a#video-title-link, a#thumbnail, a[href*="watch"]');
              const thumbEl = item.querySelector('img');
              results.push({
                rank: i + 1,
                title: titleEl ? titleEl.textContent.trim() : '',
                channel: channelEl ? channelEl.textContent.trim() : '',
                views: viewsEl ? viewsEl.textContent.trim() : '',
                url: linkEl ? linkEl.href : '',
                thumbnail: thumbEl ? thumbEl.src : ''
              });
            });
            if (results.length === 0) {
              return JSON.stringify([{info: "No videos found. Page may still be loading.", url: window.location.href}]);
            }
            return JSON.stringify(results);
          })()
        """

        // youtube/inspiration — get AI-suggested topics from Studio
        let ytInspiration = """
        site: youtube
        name: inspiration
        description: Get AI-suggested video topics from YouTube Studio Inspiration tab
        auth: cookie
        domain: youtube.com
        requiresBrowser: true
        preNavigate: https://studio.youtube.com
        waitSeconds: 5
        script: |
          (() => {
            // Try to find and click the Inspiration tab
            const tabs = document.querySelectorAll('[role="tab"], .navigation-item, a[href*="inspiration"]');
            let inspirationTab = null;
            tabs.forEach(tab => {
              if (tab.textContent.toLowerCase().includes('inspiration')) {
                inspirationTab = tab;
              }
            });
            if (inspirationTab) {
              inspirationTab.click();
              return JSON.stringify([{status: "navigating", message: "Clicked Inspiration tab. Run again in a few seconds to get topics."}]);
            }
            // If already on inspiration page, extract topics
            const topics = document.querySelectorAll('[class*="inspiration-card"], [class*="topic-card"], [class*="suggestion"]');
            const results = [];
            topics.forEach((card, i) => {
              const titleEl = card.querySelector('h3, .title, [class*="title"]');
              const descEl = card.querySelector('p, .description, [class*="description"]');
              if (titleEl) {
                results.push({
                  rank: i + 1,
                  topic: titleEl.textContent.trim(),
                  description: descEl ? descEl.textContent.trim() : ''
                });
              }
            });
            if (results.length === 0) {
              return JSON.stringify([{info: "No inspiration topics found. Try navigating to the Inspiration tab manually.", url: window.location.href}]);
            }
            return JSON.stringify(results);
          })()
        """

        // youtube/post — navigate to upload page
        let ytPost = """
        site: youtube
        name: post
        description: Navigate to YouTube video upload page
        auth: cookie
        domain: youtube.com
        requiresBrowser: true
        preNavigate: https://www.youtube.com/upload
        waitSeconds: 5
        script: |
          (() => {
            return JSON.stringify([{
              status: "ready",
              message: "YouTube upload page loaded. Use upload to select video file, then fill title and description.",
              url: window.location.href,
              tips: "Wait for 'Checks complete' before publishing. Title max 100 chars."
            }]);
          })()
        """

        for yaml in [ytProfile, ytTrending, ytInspiration, ytPost] {
            try? register(yaml: yaml)
        }
    }

    // MARK: - TikTok Adapters

    private func registerTikTokAdapters() {
        // tiktok/profile — get TikTok profile info
        let ttProfile = """
        site: tiktok
        name: profile
        description: Get TikTok creator profile info
        auth: cookie
        domain: tiktok.com
        requiresBrowser: true
        preNavigate: https://www.tiktok.com/creator-center/overview
        waitSeconds: 5
        script: |
          (() => {
            const nameEl = document.querySelector('[class*="user-name"], [class*="nickname"], .creator-name, h2');
            const handleEl = document.querySelector('[class*="user-handle"], [class*="unique-id"]');
            const followersEl = document.querySelector('[class*="follower-count"], [data-e2e="followers-count"]');
            const followingEl = document.querySelector('[class*="following-count"], [data-e2e="following-count"]');
            const likesEl = document.querySelector('[class*="likes-count"], [data-e2e="likes-count"]');
            const avatarEl = document.querySelector('[class*="avatar"] img, .avatar img');
            return JSON.stringify([{
              platform: "tiktok",
              name: nameEl ? nameEl.textContent.trim() : '',
              handle: handleEl ? handleEl.textContent.trim() : '',
              followers: followersEl ? followersEl.textContent.trim() : '',
              following: followingEl ? followingEl.textContent.trim() : '',
              likes: likesEl ? likesEl.textContent.trim() : '',
              avatar: avatarEl ? avatarEl.src : '',
              url: window.location.href
            }]);
          })()
        """

        // tiktok/trending — get trending content/topics
        let ttTrending = """
        site: tiktok
        name: trending
        description: Get trending topics and hashtags from TikTok
        auth: cookie
        domain: tiktok.com
        requiresBrowser: true
        preNavigate: https://www.tiktok.com/discover
        waitSeconds: 5
        args:
          limit:
            type: int
            default: 20
            description: Number of trending items to return
        script: |
          (() => {
            const limit = parseInt(__adapterArgs.limit) || 20;
            // Try trending hashtags
            const cards = document.querySelectorAll('[class*="DivCardContainer"], [class*="trending-item"], [class*="discover-card"]');
            const results = [];
            cards.forEach((card, i) => {
              if (i >= limit) return;
              const titleEl = card.querySelector('h3, [class*="title"], a');
              const viewsEl = card.querySelector('[class*="views"], [class*="count"], span');
              const linkEl = card.querySelector('a[href*="/tag/"], a[href*="/discover/"]');
              if (titleEl) {
                results.push({
                  rank: i + 1,
                  topic: titleEl.textContent.trim(),
                  views: viewsEl ? viewsEl.textContent.trim() : '',
                  url: linkEl ? linkEl.href : ''
                });
              }
            });
            if (results.length === 0) {
              return JSON.stringify([{info: "No trending items found. Try loading the page first.", url: window.location.href}]);
            }
            return JSON.stringify(results);
          })()
        """

        // tiktok/inspiration — get content inspiration from Creator Center
        let ttInspiration = """
        site: tiktok
        name: inspiration
        description: Get content inspiration from TikTok Creator Center
        auth: cookie
        domain: tiktok.com
        requiresBrowser: true
        preNavigate: https://www.tiktok.com/creator-center/content-inspiration
        waitSeconds: 5
        script: |
          (() => {
            const cards = document.querySelectorAll('[class*="inspiration"], [class*="topic-card"], [class*="suggestion"]');
            const results = [];
            cards.forEach((card, i) => {
              const titleEl = card.querySelector('h3, .title, [class*="title"]');
              const descEl = card.querySelector('p, .description, [class*="desc"]');
              const trendEl = card.querySelector('[class*="trend"], [class*="views"]');
              if (titleEl) {
                results.push({
                  rank: i + 1,
                  topic: titleEl.textContent.trim(),
                  description: descEl ? descEl.textContent.trim() : '',
                  trend: trendEl ? trendEl.textContent.trim() : ''
                });
              }
            });
            if (results.length === 0) {
              return JSON.stringify([{info: "No inspiration found. Page may need to load.", url: window.location.href}]);
            }
            return JSON.stringify(results);
          })()
        """

        // tiktok/post — navigate to upload page
        let ttPost = """
        site: tiktok
        name: post
        description: Navigate to TikTok video upload page
        auth: cookie
        domain: tiktok.com
        requiresBrowser: true
        preNavigate: https://www.tiktok.com/creator-center/upload
        waitSeconds: 5
        script: |
          (() => {
            return JSON.stringify([{
              status: "ready",
              message: "TikTok upload page loaded. Upload video (max 30GB, 60min, mp4 recommended), then fill caption.",
              url: window.location.href
            }]);
          })()
        """

        for yaml in [ttProfile, ttTrending, ttInspiration, ttPost] {
            try? register(yaml: yaml)
        }
    }
}
