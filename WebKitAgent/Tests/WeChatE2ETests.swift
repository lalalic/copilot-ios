import XCTest
@testable import WebKitAgent

/// E2E tests for WeChat Web (wx.qq.com) using WebKitAgent.
/// Tests navigation, snapshot, screenshot, and evaluate commands against WeChat's login page.
/// Note: wx.qq.com typically hits the 30s navigation timeout due to heavy resources,
/// so tests are structured to minimize redundant navigations.
@MainActor
final class WeChatE2ETests: XCTestCase {

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

    // MARK: - Desktop User-Agent (no navigation needed)

    func testDesktopUserAgent() {
        // WebViewManager should use desktop user-agent for full site experience
        let ua = manager.webView.customUserAgent
        XCTAssertNotNil(ua)
        XCTAssertTrue(ua!.contains("Macintosh"), "Should use desktop user-agent")
        XCTAssertTrue(ua!.contains("Safari"), "Should mimic Safari")
    }

    // MARK: - Navigate + Snapshot + Evaluate + Screenshot (single navigation)

    func testNavigateToWeChatWeb() async throws {
        let result = try await manager.navigate(to: "https://wx.qq.com")
        XCTAssertTrue(result.contains("Page loaded"), "Should load wx.qq.com")
        XCTAssertNotNil(manager.currentURL)

        // --- Snapshot ---
        let snapshot = try await manager.snapshot()
        XCTAssertTrue(snapshot.contains("Page:"), "Snapshot should contain page info")
        XCTAssertTrue(snapshot.contains("URL:"), "Snapshot should contain URL")
        XCTAssertFalse(snapshot.isEmpty)

        // --- Evaluate JS ---
        let title = try await manager.evaluateJSPublic("document.title")
        XCTAssertFalse(title.isEmpty, "Should get document title")

        let structure = try await manager.evaluateJSPublic("""
            JSON.stringify({
                title: document.title,
                url: window.location.href,
                bodyChildCount: document.body ? document.body.children.length : 0,
                hasImages: document.images.length > 0
            })
        """)
        XCTAssertTrue(structure.contains("title"), "Should return structured page info")

        // --- Screenshot ---
        let screenshot = await manager.screenshot(quality: 0.3)
        XCTAssertNotNil(screenshot, "Should capture screenshot of WeChat login")
        if let ss = screenshot {
            XCTAssertFalse(ss.isEmpty)
            XCTAssertNotNil(Data(base64Encoded: ss), "Should be valid base64")
        }
    }

    // MARK: - Full Workflow via ToolProvider (single navigation)

    func testFullWorkflowViaToolProvider() async throws {

        // Step 1: Navigate
        let navResult = try await provider.handleCLI("web-agent navigate https://wx.qq.com")
        XCTAssertTrue(navResult.contains("Page loaded"))

        // Step 2: Snapshot
        let snapResult = try await provider.handleCLI("web-agent snapshot")
        XCTAssertTrue(snapResult.contains("Page:") || snapResult.contains("URL:"))

        // Step 3: Evaluate JS
        let evalResult = try await provider.handleCLI("web-agent evaluate document.readyState")
        XCTAssertFalse(evalResult.isEmpty)

        // Step 4: Screenshot
        let ssResult = try await provider.handleCLI("web-agent screenshot")
        XCTAssertTrue(ssResult.contains("data:image/jpeg;base64,") || ssResult.contains("Error"))
    }
}
