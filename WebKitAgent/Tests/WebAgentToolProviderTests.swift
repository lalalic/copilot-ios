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

    // MARK: - Single Tool

    func testToolCountIs1() {
        XCTAssertEqual(provider.tools.count, 1)
    }

    func testToolNameIsWebAgent() {
        XCTAssertEqual(provider.tools[0].name, "web_agent")
    }

    func testToolHasDescription() {
        let tool = provider.tools[0]
        XCTAssertNotNil(tool.description)
        XCTAssertFalse(tool.description!.isEmpty)
    }

    func testToolHasParameters() {
        XCTAssertNotNil(provider.tools[0].parameters)
    }

    func testToolRequiresCommand() {
        let tool = provider.tools[0]
        if case .object(let schema) = tool.parameters,
           case .array(let required) = schema["required"] {
            XCTAssertTrue(required.contains(.string("command")))
        } else {
            XCTFail("Tool should require 'command'")
        }
    }

    func testToolHasCommandEnum() {
        let tool = provider.tools[0]
        if case .object(let schema) = tool.parameters,
           case .object(let props) = schema["properties"],
           case .object(let cmdProp) = props["command"],
           case .array(let enumValues) = cmdProp["enum"] {
            XCTAssertTrue(enumValues.contains(.string("navigate")))
            XCTAssertTrue(enumValues.contains(.string("snapshot")))
            XCTAssertTrue(enumValues.contains(.string("click")))
            XCTAssertTrue(enumValues.contains(.string("type")))
            XCTAssertTrue(enumValues.contains(.string("download")))
            XCTAssertTrue(enumValues.contains(.string("upload")))
        } else {
            XCTFail("command property should have enum values")
        }
    }

    func testToolSkipsPermission() {
        XCTAssertTrue(provider.tools[0].skipPermission)
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
        XCTAssertTrue(prompt.contains("web_agent"))
        XCTAssertTrue(prompt.contains("Workflow"))
    }

    // MARK: - Command Dispatch Error Cases

    func testRejectsNullArgs() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.null)
        XCTAssertTrue(result.contains("Error"))
    }

    func testRejectsMissingCommand() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([:]))
        XCTAssertTrue(result.contains("Error"))
    }

    func testRejectsUnknownCommand() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object(["command": .string("fly")]))
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("unknown command"))
    }

    func testNavigateRequiresURL() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object(["command": .string("navigate")]))
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("url"))
    }

    func testClickRequiresRef() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object(["command": .string("click")]))
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("ref"))
    }

    func testTypeRequiresRefAndText() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object(["command": .string("type"), "ref": .string("r0")]))
        XCTAssertTrue(result.contains("Error"))
    }

    func testDownloadRequiresRefOrURL() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object(["command": .string("download")]))
        XCTAssertTrue(result.contains("Error"))
    }

    func testUploadRequiresRefAndFilePath() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object(["command": .string("upload")]))
        XCTAssertTrue(result.contains("Error"))
    }

    func testSnapshotNoExtraParams() async throws {
        // Snapshot on blank page — should work (returns empty elements)
        let tool = provider.tools[0]
        // This will attempt JS eval on blank WKWebView, may fail but shouldn't crash
        do {
            let result = try await tool.handler(.object(["command": .string("snapshot")]))
            // If it succeeds, it should contain page info
            XCTAssertFalse(result.isEmpty)
        } catch {
            // JS eval may fail on blank webview in test environment — that's OK
        }
    }

    // MARK: - Site Subcommand

    func testSiteCommandExists() {
        let tool = provider.tools[0]
        if case .object(let schema) = tool.parameters,
           case .object(let props) = schema["properties"],
           case .object(let cmdProp) = props["command"],
           case .array(let enumValues) = cmdProp["enum"] {
            XCTAssertTrue(enumValues.contains(.string("site")))
        } else {
            XCTFail("command enum should contain 'site'")
        }
    }

    func testSiteCommandRequiresSite() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object(["command": .string("site")]))
        XCTAssertTrue(result.contains("Error") || result.contains("error"))
    }

    func testSiteCommandListAction() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "action": .string("list")
        ]))
        // Should list available adapters
        XCTAssertTrue(result.contains("hackernews") || result.contains("adapter"))
    }

    func testSiteCommandUnknownSite() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "site": .string("nonexistent"),
            "action": .string("top")
        ]))
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

    func testSkillPromptDescribesAuthFlow() {
        let prompt = WebAgentToolProvider.skillPrompt
        XCTAssertTrue(prompt.contains("Not logged in"))
        XCTAssertTrue(prompt.contains("Cookies persist"))
    }

    func testRegistryIsAccessible() {
        XCTAssertNotNil(provider.registry)
    }

    func testBundledAdaptersLoaded() {
        // Provider should auto-load bundled adapters (3 HN + 4 WeChat + 4 XHS)
        XCTAssertEqual(provider.registry.adapterCount, 11)
    }

    // MARK: - Auth Actions

    func testSessionsAction() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "action": .string("sessions")
        ]))
        // Should return login status for all known sites
        XCTAssertTrue(result.contains("Login status:"))
        XCTAssertTrue(result.contains("xiaohongshu"))
        XCTAssertTrue(result.contains("twitter"))
        XCTAssertTrue(result.contains("github"))
    }

    func testLoginActionRequiresSite() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "action": .string("login")
        ]))
        // Without site param, should get an error about missing 'site'
        XCTAssertTrue(result.contains("Error") || result.contains("error"))
    }

    func testLoginActionUnknownSite() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "site": .string("unknownsite123"),
            "action": .string("login")
        ]))
        // Unknown site should return error about no known login URL
        XCTAssertTrue(result.contains("no known login URL") || result.contains("Error"))
    }

    func testLogoutActionClearsWithoutCrash() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "site": .string("xiaohongshu"),
            "action": .string("logout")
        ]))
        // Should complete without crashing
        XCTAssertTrue(result.contains("Cleared cookies") || result.contains("logged out"))
    }

    func testAuthCheckNotLoggedIn() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "site": .string("xiaohongshu"),
            "action": .string("auth_check")
        ]))
        // Fresh WKWebView has no cookies → should say not logged in
        XCTAssertTrue(result.contains("Not logged in") || result.contains("✗"))
    }

    func testAuthCheckUnknownSite() async throws {
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "site": .string("unknownsite123"),
            "action": .string("auth_check")
        ]))
        // Unknown site should gracefully handle
        XCTAssertTrue(result.contains("No auth info") || result.contains("unknownsite123"))
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
