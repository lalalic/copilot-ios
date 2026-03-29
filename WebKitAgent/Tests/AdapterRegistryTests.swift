import XCTest
@testable import WebKitAgent

// MARK: - AdapterRegistry Tests

@MainActor
final class AdapterRegistryTests: XCTestCase {

    var registry: AdapterRegistry!

    override func setUp() {
        super.setUp()
        registry = AdapterRegistry()
    }

    override func tearDown() {
        registry = nil
        super.tearDown()
    }

    // MARK: - Registration

    func testRegisterYAMLAdapter() throws {
        let yaml = """
        site: hackernews
        name: top
        description: Top stories
        auth: none
        requiresBrowser: false
        pipeline:
          - fetch: https://api.example.com/top.json
        """
        try registry.register(yaml: yaml)
        XCTAssertEqual(registry.adapterCount, 1)
    }

    func testRegisterMultipleAdapters() throws {
        let yaml1 = """
        site: hackernews
        name: top
        description: Top stories
        auth: none
        requiresBrowser: false
        """
        let yaml2 = """
        site: hackernews
        name: new
        description: New stories
        auth: none
        requiresBrowser: false
        """
        try registry.register(yaml: yaml1)
        try registry.register(yaml: yaml2)
        XCTAssertEqual(registry.adapterCount, 2)
    }

    func testRegisterDuplicateReplacesExisting() throws {
        let yaml1 = """
        site: hackernews
        name: top
        description: Version 1
        auth: none
        requiresBrowser: false
        """
        let yaml2 = """
        site: hackernews
        name: top
        description: Version 2
        auth: none
        requiresBrowser: false
        """
        try registry.register(yaml: yaml1)
        try registry.register(yaml: yaml2)
        XCTAssertEqual(registry.adapterCount, 1)
        let adapter = registry.find(site: "hackernews", action: "top")
        XCTAssertEqual(adapter?.adapterDescription, "Version 2")
    }

    // MARK: - Find

    func testFindExistingAdapter() throws {
        let yaml = """
        site: hackernews
        name: top
        description: Top stories
        auth: none
        requiresBrowser: false
        """
        try registry.register(yaml: yaml)
        let found = registry.find(site: "hackernews", action: "top")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.site, "hackernews")
    }

    func testFindNonExistentReturnsNil() {
        let found = registry.find(site: "hackernews", action: "top")
        XCTAssertNil(found)
    }

    func testFindWrongActionReturnsNil() throws {
        let yaml = """
        site: hackernews
        name: top
        description: Top stories
        auth: none
        requiresBrowser: false
        """
        try registry.register(yaml: yaml)
        let found = registry.find(site: "hackernews", action: "search")
        XCTAssertNil(found)
    }

    // MARK: - List

    func testListAllAdapters() throws {
        let yaml1 = """
        site: hackernews
        name: top
        description: Top stories
        auth: none
        requiresBrowser: false
        """
        let yaml2 = """
        site: github
        name: trending
        description: Trending repos
        auth: none
        requiresBrowser: false
        """
        try registry.register(yaml: yaml1)
        try registry.register(yaml: yaml2)
        let list = registry.listAll()
        XCTAssertEqual(list.count, 2)
    }

    func testListForSite() throws {
        let yaml1 = """
        site: hackernews
        name: top
        description: Top stories
        auth: none
        requiresBrowser: false
        """
        let yaml2 = """
        site: hackernews
        name: new
        description: New stories
        auth: none
        requiresBrowser: false
        """
        let yaml3 = """
        site: github
        name: trending
        description: Trending repos
        auth: none
        requiresBrowser: false
        """
        try registry.register(yaml: yaml1)
        try registry.register(yaml: yaml2)
        try registry.register(yaml: yaml3)
        let list = registry.listForSite("hackernews")
        XCTAssertEqual(list.count, 2)
    }

    func testListFormattedOutput() throws {
        let yaml = """
        site: hackernews
        name: top
        description: Top HN stories
        auth: none
        requiresBrowser: false
        """
        try registry.register(yaml: yaml)
        let output = registry.listFormatted()
        XCTAssertTrue(output.contains("hackernews"))
        XCTAssertTrue(output.contains("top"))
        XCTAssertTrue(output.contains("Top HN stories"))
    }

    // MARK: - Bundled Adapters

    func testLoadBundledAdaptersFromDirectory() throws {
        // Create a temp directory with adapter files
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdapterRegistryTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let adapterYAML = """
        site: test
        name: demo
        description: Test adapter
        auth: none
        requiresBrowser: false
        pipeline:
          - fetch: https://example.com/api.json
        """
        try adapterYAML.write(to: tmpDir.appendingPathComponent("demo.yaml"),
                              atomically: true, encoding: .utf8)

        try registry.loadFromDirectory(tmpDir)
        XCTAssertEqual(registry.adapterCount, 1)
        let found = registry.find(site: "test", action: "demo")
        XCTAssertNotNil(found)
    }
}
