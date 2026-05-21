import Foundation
import CopilotSDK

/// Provides browser automation as a CLI command `web-agent` for use via `run_in_terminal`.
/// Commands: web-agent navigate|snapshot|click|type|download|upload|site|evaluate|screenshot
@MainActor
public final class WebAgentToolProvider {

    public let manager: WebViewManager
    public let registry: AdapterRegistry
    private let pipelineEngine: PipelineEngine
    public let cookieRefresh: CookieRefreshManager

    public init(manager: WebViewManager) {
        self.manager = manager
        self.registry = AdapterRegistry()
        self.pipelineEngine = PipelineEngine()
        self.cookieRefresh = CookieRefreshManager()
        registry.loadBundledAdapters()
        cookieRefresh.start()
    }

    // MARK: - Skill prompt describing web-agent CLI

    /// System prompt snippet describing the web-agent CLI commands.
    /// Append this to the agent's system prompt so the LLM knows how to use the commands.
    public static let skillPrompt = """
    You have a `web-agent` CLI for browser automation, used via `run_in_terminal`.

    Commands:
    - `web-agent navigate <url>` — Go to a URL. Waits for page load.
    - `web-agent snapshot` — Scan page for interactive elements. Returns refs like r0, r1, r2... Always snapshot after navigating or clicking.
    - `web-agent click <ref>` — Click an element (e.g. `web-agent click r5`).
    - `web-agent type <ref> <text>` — Type text into an input (e.g. `web-agent type r3 hello world`).
    - `web-agent download <ref|url> [filename]` — Download a file by element ref or URL.
    - `web-agent upload <ref> <filePath>` — Upload a file to a file input element.
    - `web-agent evaluate <script>` — Run JavaScript on the current page.
    - `web-agent screenshot` — Take a screenshot. Returns base64 PNG.
    - `web-agent set_cookies <json>` — Inject cookies. JSON array of {name, value, domain, path, ...}.
    - `web-agent get_cookies [domain]` — Export cookies as JSON, optionally filtered by domain.

    Workflow: navigate → snapshot → read refs → click/type/download → snapshot again after changes.

    You also have a `site` CLI for site-specific adapters (faster, deterministic):
    - `site list` — List all available site adapters.
    - `site sessions` — Check login status for all known sites.
    - `site <name> <action> [key=val ...]` — Run a site adapter (e.g. `site hackernews top limit=5`).
    - `site <name> login` — Navigate to login page. User logs in manually.
    - `site <name> auth_check` — Verify login status.
    - `site <name> logout` — Clear cookies.

    For known sites, prefer `site` — it's faster and deterministic.
    Auth flow: `site <name> login` → user logs in manually → `site <name> auth_check`
    """

    // MARK: - No MCP Tools (CLI only)

    public var tools: [ToolDefinition] { [] }

    // MARK: - CLI Handler

    /// Handle a `web-agent` CLI command string.
    /// Called by TerminalToolProvider when a command starts with "web-agent".
    public func handleCLI(_ command: String) async throws -> String {
        // Parse: "web-agent <subcommand> [args...]"
        let parts = command.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            return """
            Usage: web-agent <command> [args...]
            Commands: navigate, snapshot, click, type, download, upload, site, evaluate, screenshot
            """
        }
        let subcommand = String(parts[1])
        let rest = parts.count > 2 ? String(parts[2]) : ""

        switch subcommand {
        case "navigate":
            guard !rest.isEmpty else { return "Error: URL required. Usage: web-agent navigate <url>" }
            return try await manager.navigate(to: rest.trimmingCharacters(in: .whitespaces))

        case "snapshot":
            return try await manager.snapshot()

        case "click":
            guard !rest.isEmpty else { return "Error: ref required. Usage: web-agent click <ref>" }
            return try await manager.click(ref: rest.trimmingCharacters(in: .whitespaces))

        case "type":
            // Parse: "web-agent type <ref> <text>"
            let typeParts = rest.split(separator: " ", maxSplits: 1)
            guard typeParts.count >= 2 else { return "Error: ref and text required. Usage: web-agent type <ref> <text>" }
            let ref = String(typeParts[0])
            let text = String(typeParts[1])
            return try await manager.type(ref: ref, text: text, clear: true)

        case "download":
            // Parse: "web-agent download <ref|url> [filename]"
            let dlParts = rest.split(separator: " ", maxSplits: 1)
            guard !dlParts.isEmpty else { return "Error: ref or URL required. Usage: web-agent download <ref|url> [filename]" }
            let target = String(dlParts[0])
            let filename = dlParts.count > 1 ? String(dlParts[1]) : nil
            if target.hasPrefix("http://") || target.hasPrefix("https://") {
                return try await manager.download(url: target, filename: filename)
            } else {
                return try await manager.download(ref: target, filename: filename)
            }

        case "upload":
            // Parse: "web-agent upload <ref> <filePath>"
            let upParts = rest.split(separator: " ", maxSplits: 1)
            guard upParts.count >= 2 else { return "Error: ref and filePath required. Usage: web-agent upload <ref> <filePath>" }
            return try await manager.upload(ref: String(upParts[0]), filePath: String(upParts[1]))

        case "site":
            // Parse: "web-agent site <site> <action> [key=val ...]"
            return try await handleSiteCLI(rest)

        case "evaluate":
            guard !rest.isEmpty else { return "Error: script required. Usage: web-agent evaluate '<script>'" }
            return try await manager.evaluateJSPublic(rest)

        case "screenshot":
            if let base64 = await manager.screenshot() {
                return "data:image/jpeg;base64,\(base64)"
            }
            return "Error: screenshot failed"

        case "set_cookies":
            // Parse: "web-agent set_cookies <json_array>"
            // JSON array of {name, value, domain, path, ...}
            guard !rest.isEmpty else { return "Error: JSON required. Usage: web-agent set_cookies '[{\"name\":\"x\",\"value\":\"y\",\"domain\":\".example.com\",\"path\":\"/\"}]'" }
            return await setCookiesFromJSON(rest)

        case "get_cookies":
            // Parse: "web-agent get_cookies [domain]"
            let domain = rest.trimmingCharacters(in: .whitespaces)
            return await getCookiesJSON(domain: domain.isEmpty ? nil : domain)

        default:
            return "Error: unknown command '\(subcommand)'. Use: navigate, snapshot, click, type, download, upload, site, evaluate, screenshot, set_cookies, get_cookies"
        }
    }

    /// Parse and handle "site <site> <action> [key=val ...]"
    /// Called from web-agent site subcommand or directly via `site` CLI command.
    public func handleSiteCLI(_ args: String) async throws -> String {
        let parts = args.split(separator: " ")

        // "web-agent site" with no args → list all
        if parts.isEmpty {
            return registry.listFormatted()
        }

        let site = String(parts[0])

        // "web-agent site list" → list all
        if site == "list" {
            return registry.listFormatted()
        }

        // "web-agent site sessions" → check all sessions
        if site == "sessions" {
            return try await checkAllSessions()
        }

        // "web-agent site <site>" with no action → list site adapters
        guard parts.count >= 2 else {
            let siteAdapters = registry.listForSite(site)
            if siteAdapters.isEmpty {
                return "Error: no adapters for '\(site)'. Run: web-agent site list"
            }
            let names = siteAdapters.map { "  - \($0.name): \($0.adapterDescription)" }.joined(separator: "\n")
            return "Available actions for \(site):\n\(names)"
        }

        let action = String(parts[1])

        // Build args dict from remaining key=value pairs
        var siteArgs: [String: JSONValue] = [
            "site": .string(site),
            "action": .string(action)
        ]
        for part in parts.dropFirst(2) {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                siteArgs[String(kv[0])] = .string(String(kv[1]))
            }
        }

        return try await dispatchSite(args: siteArgs)
    }

    // MARK: - Site Adapter Dispatch

    private func dispatchSite(args: [String: JSONValue]) async throws -> String {
        // action=list → list all adapters
        if case .string(let action) = args["action"], action == "list" {
            return registry.listFormatted()
        }

        // action=sessions → show login status for all known sites
        if case .string(let action) = args["action"], action == "sessions" {
            return try await checkAllSessions()
        }

        guard case .string(let site) = args["site"] else {
            return "Error: 'site' parameter required for site command. Use action=\"list\" to see available adapters."
        }

        guard case .string(let action) = args["action"] else {
            // List adapters for this site
            let siteAdapters = registry.listForSite(site)
            if siteAdapters.isEmpty {
                return "Error: no adapters found for site '\(site)'. Use action=\"list\" to see all adapters."
            }
            let names = siteAdapters.map { "  - \($0.name): \($0.adapterDescription)" }.joined(separator: "\n")
            return "Available actions for \(site):\n\(names)"
        }

        // action=login → navigate to login page for the site
        if action == "login" {
            return try await handleLogin(site: site)
        }

        // action=logout → clear cookies for the site
        if action == "logout" {
            return await handleLogout(site: site)
        }

        // action=auth_check → check if user is logged in
        if action == "auth_check" {
            return await handleAuthCheck(site: site)
        }

        guard let adapter = registry.find(site: site, action: action) else {
            return "Error: adapter '\(site)/\(action)' not found. Use action=\"list\" to see available adapters."
        }

        // Collect args from the tool call
        var adapterArgs: [String: String] = [:]
        for arg in adapter.args {
            if case .string(let val) = args[arg.name] {
                adapterArgs[arg.name] = val
            } else if case .int(let val) = args[arg.name] {
                adapterArgs[arg.name] = String(val)
            } else if let defaultVal = arg.defaultValue {
                adapterArgs[arg.name] = defaultVal
            }
        }

        // Execute based on adapter type
        if adapter.requiresBrowser {
            return try await executeBrowserAdapter(adapter, args: adapterArgs)
        } else {
            return try await executePipelineAdapter(adapter, args: adapterArgs)
        }
    }

    private func executePipelineAdapter(_ adapter: YAMLAdapter, args: [String: String]) async throws -> String {
        let results = try await pipelineEngine.execute(pipeline: adapter.pipeline, args: args)

        // Apply limit from args if specified
        var limited = results
        if let limitStr = args["limit"], let limit = Int(limitStr), limit < results.count {
            limited = Array(results.prefix(limit))
        }

        return PipelineEngine.formatOutput(limited)
    }

    private func executeBrowserAdapter(_ adapter: YAMLAdapter, args: [String: String]) async throws -> String {
        // Check auth before executing if adapter requires it
        if case .cookie(let domain) = adapter.auth {
            let authResult = await manager.checkAuth(domain: domain)
            if let loggedIn = authResult["loggedIn"] as? Bool, !loggedIn {
                let reason = authResult["reason"] as? String ?? "unknown"
                let loginURL = Self.knownLoginURLs[adapter.site] ?? "https://\(domain)"
                return """
                Not logged in to \(adapter.site) (\(domain)). \(reason)
                
                To log in:
                1. Run: site \(adapter.site) login
                2. Log in manually in the browser tab
                3. Run this command again
                
                Or navigate directly to: \(loginURL)
                """
            }
        }

        // Navigate to pre-navigate URL if specified
        if let url = adapter.preNavigate {
            _ = try await manager.navigate(to: url)
        }

        // Wait if specified
        if let wait = adapter.waitSeconds, wait > 0 {
            try await Task.sleep(for: .seconds(wait))
        }

        // Execute script if present
        if let script = adapter.script {
            // Inject adapter args as JavaScript variables
            let argsJSON = try JSONSerialization.data(withJSONObject: args)
            let argsStr = String(data: argsJSON, encoding: .utf8) ?? "{}"
            let wrappedScript = "const __adapterArgs = \(argsStr);\n\(script)"

            let resultJSON = try await manager.evaluateJSPublic(wrappedScript)
            // Try to parse as JSON array for formatting
            if let data = resultJSON.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {

                // Multi-step navigation: if first result has _navigateTo, navigate there and re-run script
                if let first = json.first, let nextURL = first["_navigateTo"] as? String {
                    _ = try await manager.navigate(to: nextURL)
                    if let wait = adapter.waitSeconds, wait > 0 {
                        try await Task.sleep(for: .seconds(wait + 1))
                    } else {
                        try await Task.sleep(for: .seconds(3))
                    }
                    let retryResult = try await manager.evaluateJSPublic(wrappedScript)
                    if let retryData = retryResult.data(using: .utf8),
                       let retryJSON = try? JSONSerialization.jsonObject(with: retryData) as? [[String: Any]] {
                        return PipelineEngine.formatOutput(retryJSON)
                    }
                    return retryResult
                }

                return PipelineEngine.formatOutput(json)
            }
            return resultJSON
        }

        return "Error: browser adapter '\(adapter.site)/\(adapter.name)' has no script defined."
    }

    // MARK: - Auth Helpers

    /// URLs used to refresh cookies by visiting the site's main page.
    private static let knownRefreshURLs: [String: String] = [
        "xiaohongshu": "https://www.xiaohongshu.com",
        "wechat": "https://wx.qq.com",
        "wechat-channels": "https://channels.weixin.qq.com/platform",
        "youtube": "https://www.youtube.com",
        "tiktok": "https://www.tiktok.com",
        "twitter": "https://x.com/home",
        "bilibili": "https://www.bilibili.com",
        "zhihu": "https://www.zhihu.com",
        "weibo": "https://weibo.com",
        "github": "https://github.com",
        "reddit": "https://www.reddit.com",
    ]

    /// Known login URLs for popular sites.
    private static let knownLoginURLs: [String: String] = [
        "xiaohongshu": "https://www.xiaohongshu.com/login",
        "wechat": "https://wx.qq.com",
        "twitter": "https://x.com/i/flow/login",
        "bilibili": "https://passport.bilibili.com/login",
        "zhihu": "https://www.zhihu.com/signin",
        "weibo": "https://passport.weibo.com/signin/login",
        "douyin": "https://www.douyin.com",
        "github": "https://github.com/login",
        "reddit": "https://www.reddit.com/login",
        "youtube": "https://accounts.google.com/signin",
        "tiktok": "https://www.tiktok.com/login",
        "wechat-channels": "https://channels.weixin.qq.com/platform",
    ]

    /// Known auth domains and required cookies for popular sites.
    private static let knownAuthDomains: [(site: String, domain: String, requiredCookies: [String]?)] = [
        ("xiaohongshu", "xiaohongshu.com", ["web_session"]),
        ("wechat", "wx.qq.com", nil),
        ("wechat-channels", "channels.weixin.qq.com", ["sessionid"]),
        ("youtube", "youtube.com", ["LOGIN_INFO"]),
        ("tiktok", "tiktok.com", ["sessionid"]),
        ("twitter", "x.com", ["ct0", "auth_token"]),
        ("bilibili", "bilibili.com", ["SESSDATA"]),
        ("zhihu", "zhihu.com", ["z_c0"]),
        ("weibo", "weibo.com", ["SUB"]),
        ("github", "github.com", ["user_session"]),
        ("reddit", "reddit.com", ["reddit_session"]),
    ]

    /// Navigate to a site's login page.
    private func handleLogin(site: String) async throws -> String {
        guard let loginURL = Self.knownLoginURLs[site] else {
            return "Error: no known login URL for '\(site)'. Navigate manually: web-agent navigate <login_url>"
        }
        let result = try await manager.navigate(to: loginURL)
        return """
        Navigated to \(site) login page.
        \(result)
        
        The user can now log in manually in the browser tab.
        After login, verify with: site \(site) auth_check
        """
    }

    /// Clear cookies for a site (logout).
    private func handleLogout(site: String) async -> String {
        // Find domain for the site
        cookieRefresh.untrack(site: site)
        if let entry = Self.knownAuthDomains.first(where: { $0.site == site }) {
            await manager.clearCookies(for: entry.domain)
            return "Cleared cookies for \(site) (\(entry.domain)). You are now logged out."
        }
        // Try the site name as the domain
        await manager.clearCookies(for: "\(site).com")
        return "Cleared cookies for \(site).com. You are now logged out."
    }

    /// Check auth status for a specific site.
    private func handleAuthCheck(site: String) async -> String {
        if let entry = Self.knownAuthDomains.first(where: { $0.site == site }) {
            let status = await manager.checkAuth(domain: entry.domain, cookieNames: entry.requiredCookies)
            let loggedIn = status["loggedIn"] as? Bool ?? false
            if loggedIn {
                let count = status["cookieCount"] as? Int ?? 0
                // Track for cookie refresh
                if let refreshURL = Self.knownRefreshURLs[site] {
                    cookieRefresh.track(.init(site: site, domain: entry.domain, refreshURL: refreshURL, requiredCookies: entry.requiredCookies))
                }
                return "✓ Logged in to \(site) (\(entry.domain)) — \(count) cookies"
            } else {
                let reason = status["reason"] as? String ?? "unknown"
                cookieRefresh.untrack(site: site)
                return "✗ Not logged in to \(site) (\(entry.domain)) — \(reason)"
            }
        }
        return "No auth info configured for '\(site)'. Try: site \(site) login"
    }

    /// Check login status for all known sites.
    private func checkAllSessions() async throws -> String {
        let results = await manager.sessionStatus(domains: Self.knownAuthDomains)
        var lines: [String] = ["Login status:"]
        for result in results {
            let site = result["site"] as? String ?? "?"
            let loggedIn = result["loggedIn"] as? Bool ?? false
            let domain = result["domain"] as? String ?? "?"
            if loggedIn {
                let count = result["cookieCount"] as? Int ?? 0
                lines.append("  ✓ \(site) (\(domain)) — \(count) cookies")
                // Auto-track for cookie refresh
                if let refreshURL = Self.knownRefreshURLs[site] {
                    let entry = Self.knownAuthDomains.first(where: { $0.site == site })
                    cookieRefresh.track(.init(site: site, domain: domain, refreshURL: refreshURL, requiredCookies: entry?.requiredCookies))
                }
            } else {
                let reason = result["reason"] as? String ?? ""
                lines.append("  ✗ \(site) (\(domain)) — \(reason)")
                cookieRefresh.untrack(site: site)
            }
        }
        lines.append("")
        lines.append("To log in: site <name> login")
        lines.append("To verify: site <name> auth_check")
        return lines.joined(separator: "\n")
    }

    // MARK: - Convertio File Conversion

    /// Convert a file to another format using convertio.co.
    /// Returns the path to the converted file in the workspace downloads directory.
    public func convertFile(filePath: String, outputFormat: String) async throws -> String {
        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            return "Error: file not found at '\(filePath)'"
        }

        let inputExt = fileURL.pathExtension.lowercased()
        let targetFormat = outputFormat.lowercased()

        // 1. Navigate to convertio with format pre-selected
        let convertioURL = "https://convertio.co/\(inputExt)-\(targetFormat)/"
        _ = try await manager.navigate(to: convertioURL)
        try await Task.sleep(for: .seconds(3))

        // 2. Find and set the file input
        let setFileJS = """
        (function() {
            const inputs = document.querySelectorAll('input[type="file"]');
            if (inputs.length === 0) return JSON.stringify({error: "no_file_input"});
            // Tag it for upload
            inputs[0].setAttribute('data-wa-ref', 'convertio-file-input');
            return JSON.stringify({ok: true, count: inputs.length});
        })()
        """
        let inputResult = try await manager.evaluateJSPublic(setFileJS)
        if inputResult.contains("no_file_input") {
            return "Error: could not find file input on convertio.co"
        }

        // 3. Upload the file
        _ = try await manager.upload(ref: "convertio-file-input", filePath: filePath)
        try await Task.sleep(for: .seconds(2))

        // 4. Click the Convert button
        let clickConvertJS = """
        (function() {
            // Look for the convert/start button
            const buttons = Array.from(document.querySelectorAll('button, a'));
            const convertBtn = buttons.find(b => {
                const text = (b.textContent || '').toLowerCase().trim();
                return text === 'convert' || text === 'start' || text.includes('convert');
            });
            if (convertBtn) {
                convertBtn.click();
                return JSON.stringify({ok: true});
            }
            return JSON.stringify({error: "convert_button_not_found"});
        })()
        """
        let clickResult = try await manager.evaluateJSPublic(clickConvertJS)
        if clickResult.contains("convert_button_not_found") {
            return "Error: could not find Convert button on convertio.co"
        }

        // 5. Wait for conversion (poll for download link, max 60s)
        var downloadURL: String?
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(2))

            let checkJS = """
            (function() {
                // Look for download link/button
                const links = Array.from(document.querySelectorAll('a'));
                const dlLink = links.find(a => {
                    const text = (a.textContent || '').toLowerCase().trim();
                    const href = (a.href || '').toLowerCase();
                    return (text === 'download' || text.includes('download'))
                        && (href.includes('dl.convertio') || href.includes('/download/'));
                });
                if (dlLink) return JSON.stringify({url: dlLink.href});

                // Check for errors
                const errorEl = document.querySelector('.error-message, .alert-danger, [class*="error"]');
                if (errorEl && errorEl.textContent.trim()) {
                    return JSON.stringify({error: errorEl.textContent.trim()});
                }

                return JSON.stringify({waiting: true});
            })()
            """
            let status = try await manager.evaluateJSPublic(checkJS)
            if let data = status.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let url = json["url"] as? String {
                    downloadURL = url
                    break
                }
                if let error = json["error"] as? String {
                    return "Error: convertio conversion failed — \(error)"
                }
            }
        }

        guard let dlURL = downloadURL else {
            return "Error: convertio conversion timed out after 60s"
        }

        // 6. Download the converted file
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let outputFilename = "\(baseName).\(targetFormat)"
        let result = try await manager.download(url: dlURL, filename: outputFilename)
        return result
    }

    // MARK: - Cookie Transfer

    /// Inject cookies from JSON array into the shared WKWebsiteDataStore.
    /// JSON format: [{"name":"x","value":"y","domain":".example.com","path":"/","expiresDate":1234567890,"isSecure":true,"isHttpOnly":true}]
    private func setCookiesFromJSON(_ json: String) async -> String {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return "Error: invalid JSON array"
        }

        let store = SharedWebKitEnvironment.shared.dataStore.httpCookieStore
        var count = 0

        for item in array {
            guard let name = item["name"] as? String,
                  let value = item["value"] as? String,
                  let domain = item["domain"] as? String else {
                continue
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: (item["path"] as? String) ?? "/"
            ]

            if let expires = item["expiresDate"] as? TimeInterval {
                properties[.expires] = Date(timeIntervalSince1970: expires)
            } else if let expires = item["expires"] as? TimeInterval {
                properties[.expires] = Date(timeIntervalSince1970: expires)
            }

            if let secure = item["isSecure"] as? Bool, secure {
                properties[.secure] = "TRUE"
            } else if let secure = item["secure"] as? Bool, secure {
                properties[.secure] = "TRUE"
            }

            if let httpOnly = item["isHttpOnly"] as? Bool, httpOnly {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            } else if let httpOnly = item["httpOnly"] as? Bool, httpOnly {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }

            if let sameSite = item["sameSite"] as? String {
                properties[.sameSitePolicy] = sameSite
            }

            if let cookie = HTTPCookie(properties: properties) {
                await store.setCookie(cookie)
                count += 1
            }
        }

        return "Set \(count) cookies (of \(array.count) provided)"
    }

    /// Export cookies as JSON, optionally filtered by domain.
    private func getCookiesJSON(domain: String?) async -> String {
        let store = SharedWebKitEnvironment.shared.dataStore.httpCookieStore
        let allCookies = await store.allCookies()

        let filtered: [HTTPCookie]
        if let domain = domain {
            filtered = allCookies.filter { cookie in
                cookie.domain == domain ||
                cookie.domain == ".\(domain)" ||
                domain.hasSuffix(cookie.domain.hasPrefix(".") ? cookie.domain : ".\(cookie.domain)")
            }
        } else {
            filtered = allCookies
        }

        let items: [[String: Any]] = filtered.map { cookie in
            var dict: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path
            ]
            if let expires = cookie.expiresDate {
                dict["expiresDate"] = expires.timeIntervalSince1970
            }
            dict["isSecure"] = cookie.isSecure
            dict["isHttpOnly"] = cookie.isHTTPOnly
            if let sameSite = cookie.sameSitePolicy?.rawValue {
                dict["sameSite"] = sameSite
            }
            return dict
        }

        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return "\(filtered.count) cookies\n\(json)"
    }
}
