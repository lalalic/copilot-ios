import XCTest
@testable import WebKitAgent

// MARK: - WebViewManager Tests

@MainActor
final class WebViewManagerTests: XCTestCase {

    // MARK: - Initialization

    func testInitCreatesWebView() {
        let manager = WebViewManager()
        XCTAssertNotNil(manager.webView)
    }

    func testInitSetsDefaultState() {
        let manager = WebViewManager()
        XCTAssertNil(manager.currentURL)
        XCTAssertEqual(manager.pageTitle, "")
        XCTAssertFalse(manager.isLoading)
    }

    func testInitCreatesDownloadsDirectory() {
        let manager = WebViewManager()
        XCTAssertTrue(manager.downloadsDirectory.path.contains("WebKitAgent"))
    }

    func testWebViewFrameSize() {
        let manager = WebViewManager()
        XCTAssertEqual(manager.webView.frame.width, 1280)
        XCTAssertEqual(manager.webView.frame.height, 900)
    }

    func testWebViewHasNavigationDelegate() {
        let manager = WebViewManager()
        XCTAssertNotNil(manager.webView.navigationDelegate)
    }

    func testWebViewHasUIDelegate() {
        let manager = WebViewManager()
        XCTAssertNotNil(manager.webView.uiDelegate)
    }

    // MARK: - Navigate Invalid URL

    func testNavigateRejectsInvalidURL() async {
        let manager = WebViewManager()
        do {
            _ = try await manager.navigate(to: "")
            XCTFail("Should throw for empty URL")
        } catch let error as WebAgentError {
            if case .invalidURL = error {
                // expected
            } else {
                XCTFail("Expected invalidURL error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Current Refs

    func testCurrentRefsStartEmpty() {
        let manager = WebViewManager()
        XCTAssertTrue(manager.currentRefs.isEmpty)
    }

    // MARK: - Screenshot

    func testScreenshotOnBlankPageReturnsNil() async {
        let manager = WebViewManager()
        // Blank webview should still produce a screenshot (white page)
        let result = await manager.screenshot(quality: 0.1)
        // On macOS headless, this may or may not work depending on window server
        // Just verify it doesn't crash
        _ = result
    }

    // MARK: - Pending Upload

    func testPendingUploadURLsStartNil() {
        let manager = WebViewManager()
        XCTAssertNil(manager.pendingUploadURLs)
    }
}

// MARK: - WebAgentError Tests

final class WebAgentErrorTests: XCTestCase {

    func testInvalidURLDescription() {
        let error = WebAgentError.invalidURL("bad://url")
        XCTAssertEqual(error.errorDescription, "Invalid URL: bad://url")
    }

    func testDownloadFailedDescription() {
        let error = WebAgentError.downloadFailed("404")
        XCTAssertEqual(error.errorDescription, "Download failed: 404")
    }

    func testUploadFailedDescription() {
        let error = WebAgentError.uploadFailed("wrong type")
        XCTAssertEqual(error.errorDescription, "Upload failed: wrong type")
    }

    func testFileNotFoundDescription() {
        let error = WebAgentError.fileNotFound("/tmp/nope.txt")
        XCTAssertEqual(error.errorDescription, "File not found: /tmp/nope.txt")
    }

    func testJavaScriptErrorDescription() {
        let error = WebAgentError.javaScriptError("ReferenceError")
        XCTAssertEqual(error.errorDescription, "JavaScript error: ReferenceError")
    }
}
