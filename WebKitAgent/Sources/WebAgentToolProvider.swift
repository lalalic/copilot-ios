import Foundation
import CopilotSDK

/// Provides browser automation tools as separate CopilotSDK tools:
/// web_navigate, web_snapshot, web_click, web_type, web_download, web_upload, web_evaluate, web_screenshot, web_site
@MainActor
public final class WebAgentToolProvider {

    public let manager: WebViewManager
    public let registry: AdapterRegistry
    private let pipelineEngine: PipelineEngine

    public init(manager: WebViewManager) {
        self.manager = manager
        self.registry = AdapterRegistry()
        self.pipelineEngine = PipelineEngine()
        registry.loadBundledAdapters()
    }

    // MARK: - Skill prompt describing web tools

    /// System prompt snippet describing all web tools.
    /// Append this to the agent's system prompt so the LLM knows how to use the tools.
    public static let skillPrompt = """
    You have browser automation tools:

    - `web_navigate` — Go to a URL. Params: `url` (required). Waits for page load.
    - `web_snapshot` — Scan page for interactive elements. Returns refs like r0, r1, r2... Always snapshot after navigating or clicking to get fresh refs.
    - `web_click` — Click an element. Params: `ref` (required, e.g. "r5").
    - `web_type` — Type into an input/textarea. Params: `ref` (required), `text` (required), `clear` (optional, default true).
    - `web_download` — Download a file. Params: `ref` (element with href) OR `url` (direct URL), `filename` (optional override).
    - `web_upload` — Upload file to <input type="file">. Params: `ref` (required), `filePath` (required).
    - `web_site` — Run a site-specific adapter. Params: `site` (site name), `action` (adapter action).
      Special actions available for all sites:
        - `action=list` — List all available adapters
        - `action=sessions` — Check login status for all known sites
        - `action=login` — Navigate to the site's login page (user logs in manually in browser tab)
        - `action=logout` — Clear cookies / log out from a site
        - `action=auth_check` — Check if user is currently logged in to a site
    - `web_evaluate` — Run JavaScript on the current page. Params: `script` (required). Returns the result.
    - `web_screenshot` — Take a screenshot of the current page. Returns base64 JPEG.

    Workflow: web_navigate → web_snapshot → read refs → web_click/web_type/web_download as needed → web_snapshot again after page changes.
    For known sites, prefer `web_site` over manual navigation — it's faster and deterministic.

    Auth flow: If a site adapter says "Not logged in", run `web_site site=<name> action=login` to open the login page.
    The user logs in manually in the browser tab. Then run `web_site site=<name> action=auth_check` to verify.
    Cookies persist across app launches, so the user only needs to log in once per site.
    """

    // MARK: - Tools

    public var tools: [ToolDefinition] {
        [navigateTool, snapshotTool, clickTool, typeTool, downloadTool, uploadTool,
         siteTool, evaluateTool, screenshotTool]
    }

    private var navigateTool: ToolDefinition {
        ToolDefinition(
            name: "web_navigate",
            description: "Navigate to a URL in the browser. Waits for page load.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The URL to navigate to")
                    ])
                ]),
                "required": .array([.string("url")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: WebAgent not available" }
            guard case .object(let dict) = args,
                  case .string(let url) = dict["url"] else {
                return "Error: 'url' required"
            }
            return try await self.manager.navigate(to: url)
        }
    }

    private var snapshotTool: ToolDefinition {
        ToolDefinition(
            name: "web_snapshot",
            description: "Scan the current page for interactive elements. Returns labeled refs (r0, r1, ...) for click/type/download.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            skipPermission: true
        ) { [weak self] _ in
            guard let self else { return "Error: WebAgent not available" }
            return try await self.manager.snapshot()
        }
    }

    private var clickTool: ToolDefinition {
        ToolDefinition(
            name: "web_click",
            description: "Click an element on the page by its ref from web_snapshot.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Element ref from snapshot, e.g. 'r5'")
                    ])
                ]),
                "required": .array([.string("ref")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: WebAgent not available" }
            guard case .object(let dict) = args,
                  case .string(let ref) = dict["ref"] else {
                return "Error: 'ref' required"
            }
            return try await self.manager.click(ref: ref)
        }
    }

    private var typeTool: ToolDefinition {
        ToolDefinition(
            name: "web_type",
            description: "Type text into an input/textarea element by its ref from web_snapshot.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Element ref from snapshot, e.g. 'r5'")
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text to type")
                    ]),
                    "clear": .object([
                        "type": .string("boolean"),
                        "description": .string("Clear existing text before typing. Default true.")
                    ])
                ]),
                "required": .array([.string("ref"), .string("text")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: WebAgent not available" }
            guard case .object(let dict) = args,
                  case .string(let ref) = dict["ref"],
                  case .string(let text) = dict["text"] else {
                return "Error: 'ref' and 'text' required"
            }
            var clear = true
            if case .bool(let c) = dict["clear"] { clear = c }
            return try await self.manager.type(ref: ref, text: text, clear: clear)
        }
    }

    private var downloadTool: ToolDefinition {
        ToolDefinition(
            name: "web_download",
            description: "Download a file from a page element (by ref) or direct URL.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Element ref with href/src to download from")
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("Direct URL to download")
                    ]),
                    "filename": .object([
                        "type": .string("string"),
                        "description": .string("Override output filename")
                    ])
                ])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: WebAgent not available" }
            var ref: String?
            var url: String?
            var filename: String?
            if case .object(let dict) = args {
                if case .string(let r) = dict["ref"] { ref = r }
                if case .string(let u) = dict["url"] { url = u }
                if case .string(let f) = dict["filename"] { filename = f }
            }
            if ref == nil && url == nil {
                return "Error: 'ref' or 'url' required"
            }
            return try await self.manager.download(ref: ref, url: url, filename: filename)
        }
    }

    private var uploadTool: ToolDefinition {
        ToolDefinition(
            name: "web_upload",
            description: "Upload a file to a <input type='file'> element by its ref.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Element ref for the file input")
                    ]),
                    "filePath": .object([
                        "type": .string("string"),
                        "description": .string("Path to the file to upload")
                    ])
                ]),
                "required": .array([.string("ref"), .string("filePath")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: WebAgent not available" }
            guard case .object(let dict) = args,
                  case .string(let ref) = dict["ref"],
                  case .string(let filePath) = dict["filePath"] else {
                return "Error: 'ref' and 'filePath' required"
            }
            return try await self.manager.upload(ref: ref, filePath: filePath)
        }
    }

    private var siteTool: ToolDefinition {
        ToolDefinition(
            name: "web_site",
            description: "Run a site-specific adapter action. Use action=list to see available adapters, action=sessions to check login status.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "site": .object([
                        "type": .string("string"),
                        "description": .string("Site name (e.g. xiaohongshu, twitter)")
                    ]),
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("Action name (e.g. list, sessions, login, logout, auth_check, or adapter name)")
                    ])
                ])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: WebAgent not available" }
            var dict: [String: JSONValue] = [:]
            if case .object(let d) = args { dict = d }
            return try await self.dispatchSite(args: dict)
        }
    }

    private var evaluateTool: ToolDefinition {
        ToolDefinition(
            name: "web_evaluate",
            description: "Run JavaScript on the current page and return the result.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "script": .object([
                        "type": .string("string"),
                        "description": .string("JavaScript code to evaluate")
                    ])
                ]),
                "required": .array([.string("script")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: WebAgent not available" }
            guard case .object(let dict) = args,
                  case .string(let script) = dict["script"] else {
                return "Error: 'script' required"
            }
            return try await self.manager.evaluateJSPublic(script)
        }
    }

    private var screenshotTool: ToolDefinition {
        ToolDefinition(
            name: "web_screenshot",
            description: "Take a screenshot of the current page. Returns base64 JPEG.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            skipPermission: true
        ) { [weak self] _ in
            guard let self else { return "Error: WebAgent not available" }
            if let base64 = await self.manager.screenshot() {
                return "data:image/jpeg;base64,\(base64)"
            }
            return "Error: screenshot failed"
        }
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
                1. Run: web_site site=\(adapter.site) action=login
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
                return PipelineEngine.formatOutput(json)
            }
            return resultJSON
        }

        return "Error: browser adapter '\(adapter.site)/\(adapter.name)' has no script defined."
    }

    // MARK: - Auth Helpers

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
    ]

    /// Known auth domains and required cookies for popular sites.
    private static let knownAuthDomains: [(site: String, domain: String, requiredCookies: [String]?)] = [
        ("xiaohongshu", "xiaohongshu.com", ["web_session"]),
        ("wechat", "wx.qq.com", nil),
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
            return "Error: no known login URL for '\(site)'. Navigate manually using: web_navigate url=<login_url>"
        }
        let result = try await manager.navigate(to: loginURL)
        return """
        Navigated to \(site) login page.
        \(result)
        
        The user can now log in manually in the browser tab.
        After login, verify with: web_site site=\(site) action=auth_check
        """
    }

    /// Clear cookies for a site (logout).
    private func handleLogout(site: String) async -> String {
        // Find domain for the site
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
                return "✓ Logged in to \(site) (\(entry.domain)) — \(count) cookies"
            } else {
                let reason = status["reason"] as? String ?? "unknown"
                return "✗ Not logged in to \(site) (\(entry.domain)) — \(reason)"
            }
        }
        return "No auth info configured for '\(site)'. Try: web_site site=\(site) action=login"
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
            } else {
                let reason = result["reason"] as? String ?? ""
                lines.append("  ✗ \(site) (\(domain)) — \(reason)")
            }
        }
        lines.append("")
        lines.append("To log in: web_site site=<name> action=login")
        lines.append("To verify: web_site site=<name> action=auth_check")
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
}
