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

    // MARK: - Bundled Adapters

    func testBundledAdaptersIncludeHackerNews() {
        registry.loadBundledAdapters()
        XCTAssertNotNil(registry.find(site: "hackernews", action: "top"))
        XCTAssertNotNil(registry.find(site: "hackernews", action: "new"))
        XCTAssertNotNil(registry.find(site: "hackernews", action: "best"))
    }

    func testBundledAdaptersIncludeWeChat() {
        registry.loadBundledAdapters()
        XCTAssertNotNil(registry.find(site: "wechat", action: "login"))
        XCTAssertNotNil(registry.find(site: "wechat", action: "status"))
        XCTAssertNotNil(registry.find(site: "wechat", action: "contacts"))
        XCTAssertNotNil(registry.find(site: "wechat", action: "send"))
    }

    func testBundledAdaptersIncludeXiaohongshu() {
        registry.loadBundledAdapters()
        XCTAssertNotNil(registry.find(site: "xiaohongshu", action: "explore"))
        XCTAssertNotNil(registry.find(site: "xiaohongshu", action: "search"))
        XCTAssertNotNil(registry.find(site: "xiaohongshu", action: "profile"))
        XCTAssertNotNil(registry.find(site: "xiaohongshu", action: "post"))
    }

    func testBundledAdaptersTotalCount() {
        registry.loadBundledAdapters()
        // 3 HN + 4 WeChat + 4 XHS + 1 Convertio = 12
        XCTAssertEqual(registry.adapterCount, 12)
    }

    func testXhsAdaptersHaveCookieAuth() {
        registry.loadBundledAdapters()
        let explore = registry.find(site: "xiaohongshu", action: "explore")!
        if case .cookie(let domain) = explore.auth {
            XCTAssertEqual(domain, "xiaohongshu.com")
        } else {
            XCTFail("XHS explore adapter should use cookie auth")
        }
    }

    func testXhsAdaptersHaveScripts() {
        registry.loadBundledAdapters()
        let explore = registry.find(site: "xiaohongshu", action: "explore")!
        XCTAssertNotNil(explore.script)
        XCTAssertFalse(explore.script!.isEmpty)
    }

    func testXhsExploreHasPreNavigate() {
        registry.loadBundledAdapters()
        let explore = registry.find(site: "xiaohongshu", action: "explore")!
        XCTAssertEqual(explore.preNavigate, "https://www.xiaohongshu.com/explore")
    }

    func testWeChatContactsRequireAuth() {
        registry.loadBundledAdapters()
        let contacts = registry.find(site: "wechat", action: "contacts")!
        if case .cookie(let domain) = contacts.auth {
            XCTAssertEqual(domain, "wx.qq.com")
        } else {
            XCTFail("WeChat contacts adapter should use cookie auth")
        }
    }

    func testListFormattedGroupsBySite() {
        registry.loadBundledAdapters()
        let output = registry.listFormatted()
        XCTAssertTrue(output.contains("hackernews:"))
        XCTAssertTrue(output.contains("wechat:"))
        XCTAssertTrue(output.contains("xiaohongshu:"))
    }

    // MARK: - Convertio Adapter

    func testConvertioAdapterRegistered() {
        registry.loadBundledAdapters()
        let adapter = registry.find(site: "convertio", action: "convert")
        XCTAssertNotNil(adapter, "Convertio convert adapter should be registered")
    }

    func testConvertioAdapterProperties() {
        registry.loadBundledAdapters()
        let adapter = registry.find(site: "convertio", action: "convert")!
        XCTAssertEqual(adapter.site, "convertio")
        XCTAssertEqual(adapter.name, "convert")
        XCTAssertTrue(adapter.requiresBrowser)
    }

    func testConvertioAdapterHasCorrectArgs() {
        registry.loadBundledAdapters()
        let adapter = registry.find(site: "convertio", action: "convert")!
        let argNames = adapter.args.map(\.name)
        XCTAssertTrue(argNames.contains("filePath"), "Should have filePath arg")
        XCTAssertTrue(argNames.contains("outputFormat"), "Should have outputFormat arg")
    }

    func testConvertioAdapterDescription() {
        registry.loadBundledAdapters()
        let adapter = registry.find(site: "convertio", action: "convert")!
        XCTAssertTrue(adapter.adapterDescription.contains("convertio") || adapter.adapterDescription.contains("Convert"))
    }

    func testListFormattedIncludesConvertio() {
        registry.loadBundledAdapters()
        let output = registry.listFormatted()
        XCTAssertTrue(output.contains("convertio:"))
    }
}
