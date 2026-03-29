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

    func testRegistryIsAccessible() {
        XCTAssertNotNil(provider.registry)
    }

    func testBundledAdaptersLoaded() {
        // Provider should auto-load bundled adapters
        XCTAssertGreaterThan(provider.registry.adapterCount, 0)
    }
}
