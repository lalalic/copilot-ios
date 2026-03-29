import XCTest
@testable import WebKitAgent

// MARK: - SiteAdapter Protocol Tests

@MainActor
final class SiteAdapterTests: XCTestCase {

    // MARK: - AdapterArg

    func testAdapterArgDefaults() {
        let arg = AdapterArg(name: "limit", type: .int, defaultValue: "20", description: "Max items")
        XCTAssertEqual(arg.name, "limit")
        XCTAssertEqual(arg.type, .int)
        XCTAssertEqual(arg.defaultValue, "20")
        XCTAssertEqual(arg.description, "Max items")
    }

    func testAdapterArgStringType() {
        let arg = AdapterArg(name: "query", type: .string, defaultValue: nil, description: nil)
        XCTAssertEqual(arg.type, .string)
        XCTAssertNil(arg.defaultValue)
    }

    // MARK: - AuthStrategy

    func testAuthStrategyNone() {
        let auth = AuthStrategy.none
        if case .none = auth {
            // OK
        } else {
            XCTFail("Expected .none")
        }
    }

    func testAuthStrategyCookie() {
        let auth = AuthStrategy.cookie(domain: "x.com")
        if case .cookie(let domain) = auth {
            XCTAssertEqual(domain, "x.com")
        } else {
            XCTFail("Expected .cookie")
        }
    }

    // MARK: - YAMLAdapter

    func testYAMLAdapterParseMinimal() throws {
        let yaml = """
        site: hackernews
        name: top
        description: Top HN stories
        auth: none
        requiresBrowser: false
        """
        let adapter = try YAMLAdapter.parse(yaml)
        XCTAssertEqual(adapter.site, "hackernews")
        XCTAssertEqual(adapter.name, "top")
        XCTAssertEqual(adapter.adapterDescription, "Top HN stories")
        XCTAssertEqual(adapter.auth, .none)
        XCTAssertFalse(adapter.requiresBrowser)
        XCTAssertTrue(adapter.pipeline.isEmpty)
        XCTAssertTrue(adapter.args.isEmpty)
    }

    func testYAMLAdapterParseWithArgs() throws {
        let yaml = """
        site: hackernews
        name: top
        description: Top stories
        auth: none
        requiresBrowser: false
        args:
          limit:
            type: int
            default: 20
            description: Number of stories
        """
        let adapter = try YAMLAdapter.parse(yaml)
        XCTAssertEqual(adapter.args.count, 1)
        XCTAssertEqual(adapter.args[0].name, "limit")
        XCTAssertEqual(adapter.args[0].type, .int)
        XCTAssertEqual(adapter.args[0].defaultValue, "20")
    }

    func testYAMLAdapterParseWithPipeline() throws {
        let yaml = """
        site: hackernews
        name: top
        description: Top stories
        auth: none
        requiresBrowser: false
        pipeline:
          - fetch: https://api.example.com/data.json
          - slice: { to: 10 }
        """
        let adapter = try YAMLAdapter.parse(yaml)
        XCTAssertEqual(adapter.pipeline.count, 2)
        if case .fetch(let url) = adapter.pipeline[0] {
            XCTAssertEqual(url, "https://api.example.com/data.json")
        } else {
            XCTFail("Expected .fetch step")
        }
    }

    func testYAMLAdapterParseCookieAuth() throws {
        let yaml = """
        site: twitter
        name: trending
        description: Trending topics
        auth: cookie
        domain: x.com
        requiresBrowser: true
        """
        let adapter = try YAMLAdapter.parse(yaml)
        if case .cookie(let domain) = adapter.auth {
            XCTAssertEqual(domain, "x.com")
        } else {
            XCTFail("Expected cookie auth with domain")
        }
    }

    func testYAMLAdapterParseWithScript() throws {
        let yaml = """
        site: twitter
        name: trending
        description: Trending topics
        auth: cookie
        domain: x.com
        requiresBrowser: true
        preNavigate: https://x.com/explore
        waitSeconds: 3
        script: |
          (() => { return JSON.stringify([]); })()
        """
        let adapter = try YAMLAdapter.parse(yaml)
        XCTAssertEqual(adapter.preNavigate, "https://x.com/explore")
        XCTAssertEqual(adapter.waitSeconds, 3)
        XCTAssertNotNil(adapter.script)
        XCTAssertTrue(adapter.script!.contains("JSON.stringify"))
    }

    func testYAMLAdapterParseInvalidThrows() {
        XCTAssertThrowsError(try YAMLAdapter.parse("not a valid adapter")) { error in
            XCTAssertTrue(error is AdapterParseError)
        }
    }

    func testYAMLAdapterParseMissingSiteThrows() {
        let yaml = """
        name: top
        description: test
        auth: none
        requiresBrowser: false
        """
        XCTAssertThrowsError(try YAMLAdapter.parse(yaml))
    }
}
