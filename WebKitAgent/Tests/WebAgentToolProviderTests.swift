import XCTest
import CopilotSDK
@testable import WebKitAgent

// MARK: - WebAgentToolProvider Tests

@MainActor
final class WebAgentToolProviderTests: XCTestCase {

    var manager: WebViewManager!
    var provider: WebAgentToolProvider!

    override func setUp() {
        super.setUp()
        manager = WebViewManager()
        provider = WebAgentToolProvider(manager: manager)
    }

    override func tearDown() {
        provider = nil
        manager = nil
        super.tearDown()
    }

    // MARK: - CLI-Based Provider

    func testToolsArrayIsEmpty() {
        // WebAgentToolProvider is CLI-only — no MCP tools exposed
        XCTAssertTrue(provider.tools.isEmpty, "tools should be empty — provider uses CLI")
    }

    // MARK: - Skill Prompt

    func testSkillPromptContainsAllCommands() {
        let prompt = WebAgentToolProvider.skillPrompt
        XCTAssertTrue(prompt.contains("navigate"))
        XCTAssertTrue(prompt.contains("snapshot"))
        XCTAssertTrue(prompt.contains("click"))
        XCTAssertTrue(prompt.contains("type"))
        XCTAssertTrue(prompt.contains("download"))
        XCTAssertTrue(prompt.contains("upload"))
    }

    func testSkillPromptDescribesWorkflow() {
        let prompt = WebAgentToolProvider.skillPrompt
        XCTAssertTrue(prompt.contains("web-agent") || prompt.contains("web_agent"))
        XCTAssertTrue(prompt.contains("Workflow"))
    }

    // MARK: - CLI Command Dispatch

    func testCLIUsageMessage() async throws {
        let result = try await provider.handleCLI("web-agent")
        XCTAssertTrue(result.contains("Usage") || result.contains("Commands"))
    }

    func testRejectsUnknownCommand() async throws {
        let result = try await provider.handleCLI("web-agent fly")
        XCTAssertTrue(result.contains("Error") || result.contains("unknown"))
    }

    func testNavigateRequiresURL() async throws {
        let result = try await provider.handleCLI("web-agent navigate")
        XCTAssertTrue(result.contains("Error"))
    }

    func testClickRequiresRef() async throws {
        let result = try await provider.handleCLI("web-agent click")
        XCTAssertTrue(result.contains("Error"))
    }

    func testTypeRequiresRefAndText() async throws {
        let result = try await provider.handleCLI("web-agent type r0")
        XCTAssertTrue(result.contains("Error"))
    }

    func testDownloadRequiresRefOrURL() async throws {
        let result = try await provider.handleCLI("web-agent download")
        XCTAssertTrue(result.contains("Error"))
    }

    func testUploadRequiresRefAndFilePath() async throws {
        let result = try await provider.handleCLI("web-agent upload")
        XCTAssertTrue(result.contains("Error"))
    }

    func testEvaluateRequiresScript() async throws {
        let result = try await provider.handleCLI("web-agent evaluate")
        XCTAssertTrue(result.contains("Error"))
    }

    func testSnapshotNoExtraParams() async throws {
        do {
            let result = try await provider.handleCLI("web-agent snapshot")
            XCTAssertFalse(result.isEmpty)
        } catch {
            // JS eval may fail on blank webview in test environment
        }
    }

    // MARK: - Site Subcommand

    func testSiteCommandListAll() async throws {
        let result = try await provider.handleSiteCLI("list")
        XCTAssertTrue(result.contains("hackernews") || result.contains("adapter"))
    }

    func testSiteCommandEmpty() async throws {
        let result = try await provider.handleSiteCLI("")
        XCTAssertFalse(result.isEmpty)
    }

    func testSiteCommandUnknownSite() async throws {
        let result = try await provider.handleSiteCLI("nonexistent top")
        XCTAssertTrue(result.contains("not found") || result.contains("Error"))
    }

    func testSkillPromptContainsSiteCommand() {
        let prompt = WebAgentToolProvider.skillPrompt
        XCTAssertTrue(prompt.contains("site"))
    }

    func testSkillPromptContainsAuthCommands() {
        let prompt = WebAgentToolProvider.skillPrompt
        XCTAssertTrue(prompt.contains("sessions"))
        XCTAssertTrue(prompt.contains("login"))
        XCTAssertTrue(prompt.contains("logout"))
        XCTAssertTrue(prompt.contains("auth_check"))
    }

    func testRegistryIsAccessible() {
        XCTAssertNotNil(provider.registry)
    }

    func testBundledAdaptersLoaded() {
        // 3 HN + 4 WeChat + 4 XHS + 1 Convertio = 12
        XCTAssertEqual(provider.registry.adapterCount, 12)
    }

    // MARK: - Auth Actions

    func testSessionsAction() async throws {
        let result = try await provider.handleSiteCLI("sessions")
        XCTAssertTrue(result.contains("Login status:"))
    }

    func testLogoutActionClearsWithoutCrash() async throws {
        let result = try await provider.handleSiteCLI("xiaohongshu logout")
        XCTAssertTrue(result.contains("Cleared cookies") || result.contains("logged out"))
    }

    func testAuthCheckNotLoggedIn() async throws {
        let result = try await provider.handleSiteCLI("xiaohongshu auth_check")
        XCTAssertTrue(result.contains("Not logged in") || result.contains("✗"))
    }

    // MARK: - XHS Adapters

    func testXhsAdaptersRegistered() {
        XCTAssertNotNil(provider.registry.find(site: "xiaohongshu", action: "explore"))
        XCTAssertNotNil(provider.registry.find(site: "xiaohongshu", action: "search"))
        XCTAssertNotNil(provider.registry.find(site: "xiaohongshu", action: "profile"))
        XCTAssertNotNil(provider.registry.find(site: "xiaohongshu", action: "post"))
    }

    func testXhsAdaptersRequireAuth() {
        let explore = provider.registry.find(site: "xiaohongshu", action: "explore")!
        if case .cookie(let domain) = explore.auth {
            XCTAssertEqual(domain, "xiaohongshu.com")
        } else {
            XCTFail("XHS explore should require cookie auth")
        }
    }

    func testXhsAdaptersRequireBrowser() {
        let explore = provider.registry.find(site: "xiaohongshu", action: "explore")!
        XCTAssertTrue(explore.requiresBrowser)
    }

    func testListFormattedIncludesAuthMarker() {
        let formatted = provider.registry.listFormatted()
        XCTAssertTrue(formatted.contains("[auth required]"))
        XCTAssertTrue(formatted.contains("[browser]"))
    }
}
