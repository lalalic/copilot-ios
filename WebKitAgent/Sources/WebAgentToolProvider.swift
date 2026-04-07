import Foundation
import CopilotSDK

/// Provides a single CopilotSDK tool (`web_agent`) with sub-commands for browser automation.
/// The skill system prompt should describe available sub-commands.
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

    // MARK: - Skill prompt describing sub-commands

    /// System prompt snippet describing all web_agent sub-commands.
    /// Append this to the agent's system prompt so the LLM knows how to use the tool.
    public static let skillPrompt = """
    You have a `web_agent` tool for browser automation. Use the `command` parameter to specify the action.

    Sub-commands:
    - `navigate` — Go to a URL. Params: `url` (required). Waits for page load.
    - `snapshot` — Scan page for interactive elements. Returns refs like r0, r1, r2... Always snapshot after navigating or clicking to get fresh refs.
    - `click` — Click an element. Params: `ref` (required, e.g. "r5").
    - `type` — Type into an input/textarea. Params: `ref` (required), `text` (required), `clear` (optional, default true).
    - `download` — Download a file. Params: `ref` (element with href) OR `url` (direct URL), `filename` (optional override).
    - `upload` — Upload file to <input type="file">. Params: `ref` (required), `filePath` (required).
    - `site` — Run a site-specific adapter. Params: `site` (site name), `action` (adapter name).
      Special actions available for all sites:
        - `action=list` — List all available adapters
        - `action=sessions` — Check login status for all known sites
        - `action=login` — Navigate to the site's login page (user logs in manually in browser tab)
        - `action=logout` — Clear cookies / log out from a site
        - `action=auth_check` — Check if user is currently logged in to a site
    - `evaluate` — Run JavaScript on the current page. Params: `script` (required). Returns the result.
    - `screenshot` — Take a screenshot of the current page. Returns base64 JPEG.

    Workflow: navigate → snapshot → read refs → click/type/download as needed → snapshot again after page changes.
    For known sites, prefer `site` command over manual navigation — it's faster and deterministic.

    Auth flow: If a site adapter says "Not logged in", run `site action=login site=<name>` to open the login page.
    The user logs in manually in the browser tab. Then run `site action=auth_check site=<name>` to verify.
    Cookies persist across app launches, so the user only needs to log in once per site.
    """

    // MARK: - Single Tool

    public var tools: [ToolDefinition] {
        [webAgentTool]
    }

    private var webAgentTool: ToolDefinition {
        ToolDefinition(
            name: "web_agent",
            description: "Browser automation tool. Use 'command' to specify action: navigate, snapshot, click, type, download, upload. See skill prompt for details.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("navigate"), .string("snapshot"), .string("click"),
                            .string("type"), .string("download"), .string("upload"),
                            .string("site"), .string("evaluate"), .string("screenshot")
                        ]),
                        "description": .string("The sub-command to execute")
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("URL for navigate or download")
                    ]),
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Element ref from snapshot, e.g. 'r5'")
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text to type (for type command)")
                    ]),
                    "clear": .object([
                        "type": .string("boolean"),
                        "description": .string("Clear existing text before typing. Default true.")
                    ]),
                    "filename": .object([
                        "type": .string("string"),
                        "description": .string("Override filename for download")
                    ]),
                    "filePath": .object([
                        "type": .string("string"),
                        "description": .string("File path for upload")
                    ]),
                    "site": .object([
                        "type": .string("string"),
                        "description": .string("Site name for site command (e.g. hackernews)")
                    ]),
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("Action name for site command (e.g. top, list)")
                    ]),
                    "script": .object([
                        "type": .string("string"),
                        "description": .string("JavaScript code to evaluate (for evaluate command)")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: WebAgent not available" }
            guard case .object(let dict) = args,
                  case .string(let command) = dict["command"] else {
                return "Error: 'command' parameter required"
            }
            return try await self.dispatch(command: command, args: dict)
        }
    }

    // MARK: - Dispatch

    private func dispatch(command: String, args: [String: JSONValue]) async throws -> String {
        switch command {
        case "navigate":
            guard case .string(let url) = args["url"] else {
                return "Error: 'url' required for navigate"
            }
            return try await manager.navigate(to: url)

        case "snapshot":
            return try await manager.snapshot()

        case "click":
            guard case .string(let ref) = args["ref"] else {
                return "Error: 'ref' required for click"
            }
            return try await manager.click(ref: ref)

        case "type":
            guard case .string(let ref) = args["ref"],
                  case .string(let text) = args["text"] else {
                return "Error: 'ref' and 'text' required for type"
            }
            var clear = true
            if case .bool(let c) = args["clear"] { clear = c }
            return try await manager.type(ref: ref, text: text, clear: clear)

        case "download":
            var ref: String?
            var url: String?
            var filename: String?
            if case .string(let r) = args["ref"] { ref = r }
            if case .string(let u) = args["url"] { url = u }
            if case .string(let f) = args["filename"] { filename = f }
            if ref == nil && url == nil {
                return "Error: 'ref' or 'url' required for download"
            }
            return try await manager.download(ref: ref, url: url, filename: filename)

        case "upload":
            guard case .string(let ref) = args["ref"],
                  case .string(let filePath) = args["filePath"] else {
                return "Error: 'ref' and 'filePath' required for upload"
            }
            return try await manager.upload(ref: ref, filePath: filePath)

        case "site":
            return try await dispatchSite(args: args)

        case "evaluate":
            guard case .string(let script) = args["script"] else {
                return "Error: 'script' parameter required for evaluate"
            }
            return try await manager.evaluateJSPublic(script)

        case "screenshot":
            if let base64 = await manager.screenshot() {
                return "data:image/jpeg;base64,\(base64)"
            }
            return "Error: screenshot failed"

        default:
            return "Error: unknown command '\(command)'. Use: navigate, snapshot, click, type, download, upload, site"
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
                1. Run: web_agent command=site site=\(adapter.site) action=login
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
            return "Error: no known login URL for '\(site)'. Navigate manually using: web_agent command=navigate url=<login_url>"
        }
        let result = try await manager.navigate(to: loginURL)
        return """
        Navigated to \(site) login page.
        \(result)
        
        The user can now log in manually in the browser tab.
        After login, verify with: web_agent command=site site=\(site) action=auth_check
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
        return "No auth info configured for '\(site)'. Try: web_agent command=site site=\(site) action=login"
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
        lines.append("To log in: web_agent command=site site=<name> action=login")
        lines.append("To verify: web_agent command=site site=<name> action=auth_check")
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
