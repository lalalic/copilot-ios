import XCTest
@testable import WebKitAgent

/// End-to-end integration tests that load real web pages in WKWebView.
/// These tests verify the full navigate → snapshot → click → type workflow.
@MainActor
final class WebAgentE2ETests: XCTestCase {

    var manager: WebViewManager!

    override func setUp() {
        super.setUp()
        manager = WebViewManager()
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Navigate + Snapshot

    func testNavigateToExampleDotCom() async throws {
        let result = try await manager.navigate(to: "https://example.com")
        XCTAssertTrue(result.contains("Page loaded"))
        XCTAssertTrue(result.contains("example") || result.contains("Example"))
        XCTAssertNotNil(manager.currentURL)
    }

    func testSnapshotFindsInteractiveElements() async throws {
        _ = try await manager.navigate(to: "https://example.com")
        let snapshot = try await manager.snapshot()

        // example.com has at least one link ("More information...")
        XCTAssertTrue(snapshot.contains("Page:"))
        XCTAssertTrue(snapshot.contains("URL:"))
        XCTAssertTrue(snapshot.contains("r0"))
        XCTAssertTrue(snapshot.contains("[a"))
        XCTAssertTrue(snapshot.contains("interactive elements"))
    }

    func testSnapshotAssignsRefs() async throws {
        _ = try await manager.navigate(to: "https://example.com")
        _ = try await manager.snapshot()

        // Should have at least one ref stored
        XCTAssertFalse(manager.currentRefs.isEmpty)
        XCTAssertNotNil(manager.currentRefs["r0"])
    }

    // MARK: - Click

    func testClickLinkOnExampleDotCom() async throws {
        _ = try await manager.navigate(to: "https://example.com")
        _ = try await manager.snapshot()

        // Click the "More information..." link (r0)
        let clickResult = try await manager.click(ref: "r0")
        XCTAssertTrue(clickResult.contains("Clicked"))
        XCTAssertTrue(clickResult.contains("r0"))
    }

    func testClickNonExistentRef() async throws {
        _ = try await manager.navigate(to: "https://example.com")
        _ = try await manager.snapshot()

        let result = try await manager.click(ref: "r999")
        XCTAssertTrue(result.contains("failed") || result.contains("not found"),
                       "Should report element not found for invalid ref")
    }

    // MARK: - Navigate + Snapshot on Form Page

    func testSnapshotOnSearchPage() async throws {
        // Use a page with inputs — httpbin has a form
        _ = try await manager.navigate(to: "https://httpbin.org/forms/post")
        let snapshot = try await manager.snapshot()

        // Should find input fields
        XCTAssertTrue(snapshot.contains("[input"), "Should find input elements")
        XCTAssertTrue(snapshot.contains("[button") || snapshot.contains("submit"),
                       "Should find submit button")
    }

    func testTypeIntoInput() async throws {
        _ = try await manager.navigate(to: "https://httpbin.org/forms/post")
        _ = try await manager.snapshot()

        // Find first input ref
        let firstInputRef = manager.currentRefs.keys.sorted().first { key in
            manager.currentRefs[key]?.contains("[input") == true
        }
        guard let ref = firstInputRef else {
            XCTFail("No input element found on page")
            return
        }

        let result = try await manager.type(ref: ref, text: "Test Input", clear: true)
        XCTAssertTrue(result.contains("Typed"))
        XCTAssertTrue(result.contains("Test Input"))
    }

    // MARK: - Screenshot

    func testScreenshotProducesBase64() async throws {
        _ = try await manager.navigate(to: "https://example.com")
        let screenshot = await manager.screenshot(quality: 0.1)

        XCTAssertNotNil(screenshot, "Screenshot should produce base64 data")
        if let ss = screenshot {
            XCTAssertFalse(ss.isEmpty)
            // Verify it's valid base64
            XCTAssertNotNil(Data(base64Encoded: ss), "Should be valid base64")
        }
    }

    // MARK: - Snapshot Refresh

    func testSnapshotRefreshClearsOldRefs() async throws {
        _ = try await manager.navigate(to: "https://example.com")
        _ = try await manager.snapshot()
        let firstRefs = manager.currentRefs

        // Snapshot again — should have fresh refs
        _ = try await manager.snapshot()
        let secondRefs = manager.currentRefs

        // Both should have elements (same page)
        XCTAssertFalse(firstRefs.isEmpty)
        XCTAssertFalse(secondRefs.isEmpty)
        // Ref descriptions should match (same page, same elements)
        XCTAssertEqual(firstRefs.count, secondRefs.count)
    }

    // MARK: - Full Workflow via ToolProvider

    func testToolProviderNavigateAndSnapshot() async throws {
        let provider = WebAgentToolProvider(manager: manager)

        // Navigate
        let navResult = try await provider.handleCLI("web-agent navigate https://example.com")
        XCTAssertTrue(navResult.contains("Page loaded"))

        // Snapshot
        let snapResult = try await provider.handleCLI("web-agent snapshot")
        XCTAssertTrue(snapResult.contains("r0"))
        XCTAssertTrue(snapResult.contains("interactive elements"))

        // Click
        let clickResult = try await provider.handleCLI("web-agent click r0")
        XCTAssertTrue(clickResult.contains("Clicked"))
    }

    // MARK: - Download

    func testDownloadByURL() async throws {
        // Download a small known file
        let result = try await manager.download(
            url: "https://httpbin.org/robots.txt",
            filename: "test-robots.txt"
        )
        XCTAssertTrue(result.contains("Downloaded"))
        XCTAssertTrue(result.contains("test-robots.txt"))

        // Verify file exists
        let filePath = manager.downloadsDirectory.appendingPathComponent("test-robots.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath.path))

        // Cleanup
        try? FileManager.default.removeItem(at: filePath)
    }
}
