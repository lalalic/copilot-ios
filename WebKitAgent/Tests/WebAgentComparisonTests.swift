import XCTest
@testable import WebKitAgent

/// Baseline comparison tests: verifies WebKitAgent finds the same essential elements
/// that agent-browser (or any browser automation tool) would find on real websites.
///
/// Baselines captured via fetch_webpage on 2026-03-26.
/// Tests verify KEY elements are found — not exact match, since dynamic content varies.
@MainActor
final class WebAgentComparisonTests: XCTestCase {

    var manager: WebViewManager!

    override func setUp() {
        super.setUp()
        manager = WebViewManager()
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - example.com baseline

    /// Baseline (agent-browser): 1 link "Learn more" → iana.org/domains/example
    func testExampleDotComBaseline() async throws {
        _ = try await manager.navigate(to: "https://example.com")
        let snapshot = try await manager.snapshot()

        // Must find: exactly 1 interactive element
        XCTAssertTrue(snapshot.contains("1 interactive elements"),
                       "example.com must have exactly 1 interactive element")

        // Must find: anchor link to iana.org
        XCTAssertTrue(snapshot.contains("[a"), "Must find an <a> element")
        XCTAssertTrue(snapshot.contains("iana.org") || snapshot.contains("More"),
                       "Must find the 'More information' / IANA link")
    }

    // MARK: - httpbin.org/forms/post baseline

    /// Baseline (agent-browser):
    /// - Customer name (text input)
    /// - Telephone (tel input)
    /// - E-mail (email input)
    /// - Pizza Size: 3 radio buttons (small, medium, large)
    /// - Pizza Toppings: 4 checkboxes (bacon, cheese, onion, mushroom)
    /// - Delivery time (time input)
    /// - Delivery instructions (textarea)
    /// - Submit order (button)
    func testHttpbinFormBaseline() async throws {
        _ = try await manager.navigate(to: "https://httpbin.org/forms/post")
        let snapshot = try await manager.snapshot()
        let allRefs = manager.currentRefs.values.joined(separator: "\n")

        // Essential: text input (customer name)
        XCTAssertTrue(allRefs.contains("type=text"), "Must find text input (customer name)")

        // Essential: tel input (telephone)
        XCTAssertTrue(allRefs.contains("type=tel"), "Must find tel input (telephone)")

        // Essential: email input
        XCTAssertTrue(allRefs.contains("type=email"), "Must find email input")

        // Essential: radio buttons for pizza size
        XCTAssertTrue(allRefs.contains("type=radio"), "Must find radio buttons (pizza size)")
        XCTAssertTrue(allRefs.contains("value=\"small\""), "Must find 'small' radio option")
        XCTAssertTrue(allRefs.contains("value=\"medium\""), "Must find 'medium' radio option")
        XCTAssertTrue(allRefs.contains("value=\"large\""), "Must find 'large' radio option")

        // Essential: checkboxes for toppings
        XCTAssertTrue(allRefs.contains("type=checkbox"), "Must find checkboxes (toppings)")
        XCTAssertTrue(allRefs.contains("value=\"bacon\""), "Must find 'bacon' checkbox")
        XCTAssertTrue(allRefs.contains("value=\"cheese\""), "Must find 'cheese' checkbox")
        XCTAssertTrue(allRefs.contains("value=\"onion\""), "Must find 'onion' checkbox")
        XCTAssertTrue(allRefs.contains("value=\"mushroom\""), "Must find 'mushroom' checkbox")

        // Essential: time input
        XCTAssertTrue(allRefs.contains("type=time"), "Must find time input (delivery time)")

        // Essential: textarea
        XCTAssertTrue(allRefs.contains("[textarea"), "Must find textarea (delivery instructions)")

        // Essential: submit button
        XCTAssertTrue(allRefs.contains("[button") || allRefs.contains("type=submit"),
                       "Must find submit button")
        XCTAssertTrue(allRefs.contains("Submit order"),
                       "Submit button must say 'Submit order'")

        // Total: 13 elements (3 text + 3 radio + 4 checkbox + time + textarea + button)
        XCTAssertEqual(manager.currentRefs.count, 13,
                        "httpbin form should have exactly 13 interactive elements")
    }

    // MARK: - news.ycombinator.com baseline

    /// Baseline (agent-browser):
    /// - Nav: new, past, comments, ask, show, jobs, submit, login
    /// - 30 story links + hide/comments links
    /// - Footer: Guidelines, FAQ, Lists, API, Security, Legal, Apply to YC, Contact
    /// - Search input + "More" pagination
    func testHackerNewsBaseline() async throws {
        _ = try await manager.navigate(to: "https://news.ycombinator.com")
        let snapshot = try await manager.snapshot()
        let allRefs = manager.currentRefs.values.joined(separator: "\n")

        // Essential nav links
        XCTAssertTrue(allRefs.contains("new") || allRefs.contains("newest"),
                       "Must find 'new' nav link")
        XCTAssertTrue(allRefs.contains("submit"), "Must find 'submit' nav link")
        XCTAssertTrue(allRefs.contains("login"), "Must find 'login' link")

        // Essential: many story links (30 stories × title + hide + comments)
        let linkCount = manager.currentRefs.values.filter { $0.contains("[a") }.count
        XCTAssertGreaterThan(linkCount, 30,
                              "Must find 30+ links (stories + nav + footer)")

        // Essential: footer links
        XCTAssertTrue(allRefs.contains("Guidelines") || allRefs.contains("guidelines"),
                       "Must find 'Guidelines' footer link")

        // Essential: search input
        XCTAssertTrue(allRefs.contains("[input"), "Must find search input")

        // Essential: "More" pagination
        XCTAssertTrue(allRefs.contains("More"), "Must find 'More' pagination link")

        // Should have 50+ elements total
        XCTAssertGreaterThan(manager.currentRefs.count, 50,
                              "HN should have 50+ interactive elements")

        print("=== HN: \(manager.currentRefs.count) elements, \(linkCount) links ===")
    }

    // MARK: - Determinism

    func testSnapshotIsDeterministic() async throws {
        _ = try await manager.navigate(to: "https://example.com")
        let snap1 = try await manager.snapshot()
        let snap2 = try await manager.snapshot()
        XCTAssertEqual(snap1, snap2, "Same page must produce identical snapshots")
    }

    // MARK: - Full tool workflow

    func testToolProviderWorkflow() async throws {
        let provider = WebAgentToolProvider(manager: manager)

        let nav = try await provider.handleCLI("web-agent navigate https://example.com")
        XCTAssertTrue(nav.contains("Page loaded"))

        let snap = try await provider.handleCLI("web-agent snapshot")
        XCTAssertTrue(snap.contains("r0"))

        let click = try await provider.handleCLI("web-agent click r0")
        XCTAssertTrue(click.contains("Clicked"))
    }
}
