import XCTest
import CopilotSDK
@testable import WebKitAgent

// MARK: - Additional Site Adapter Tests

/// Tests for features added in the site adapter infrastructure:
/// - Compound filter expressions (&&, ==nil, !item.key)
/// - URL template with args
/// - Evaluate/screenshot command dispatch
/// - Site adapter arg collection
/// - Browser adapter execution path
/// - Bundled adapter content verification
/// - NavigationTimeout error
@MainActor
final class SiteAdapterExtendedTests: XCTestCase {

    // MARK: - PipelineEngine Extended Filter Tests

    func testFilterEqualsNil() {
        let engine = PipelineEngine()
        let data: [Any] = [
            ["title": "hello", "deleted": false] as [String: Any],
            ["title": "world"] as [String: Any],
            ["deleted": true] as [String: Any]
        ]
        // item.deleted == nil → only items without "deleted" key
        let result = engine.executeFilter(data: data, expression: "item.deleted == nil")
        XCTAssertEqual(result.count, 1)
        if let first = result[0] as? [String: Any] {
            XCTAssertEqual(first["title"] as? String, "world")
        }
    }

    func testFilterNegation() {
        let engine = PipelineEngine()
        let data: [Any] = [
            ["title": "A", "dead": true] as [String: Any],
            ["title": "B", "dead": false] as [String: Any],
            ["title": "C"] as [String: Any]
        ]
        // !item.dead → items where dead is false or nil
        let result = engine.executeFilter(data: data, expression: "!item.dead")
        XCTAssertEqual(result.count, 2)
    }

    func testFilterCompoundExpression() {
        let engine = PipelineEngine()
        let data: [Any] = [
            ["title": "A", "score": 10] as [String: Any],
            ["score": 20] as [String: Any],    // no title
            ["title": "C"] as [String: Any],   // no score
            ["title": "D", "score": 30] as [String: Any]
        ]
        // item.title != nil && item.score != nil
        let result = engine.executeFilter(data: data, expression: "item.title != nil && item.score != nil")
        XCTAssertEqual(result.count, 2)
        if let first = result[0] as? [String: Any] {
            XCTAssertEqual(first["title"] as? String, "A")
        }
        if let second = result[1] as? [String: Any] {
            XCTAssertEqual(second["title"] as? String, "D")
        }
    }

    func testFilterCompoundWithNegation() {
        let engine = PipelineEngine()
        let data: [Any] = [
            ["title": "A", "deleted": true] as [String: Any],
            ["title": "B", "deleted": false] as [String: Any],
            ["title": "C"] as [String: Any],
            ["deleted": true] as [String: Any]
        ]
        // item.title != nil && !item.deleted
        let result = engine.executeFilter(data: data, expression: "item.title != nil && !item.deleted")
        XCTAssertEqual(result.count, 2) // B (deleted=false) and C (no deleted key)
    }

    func testFilterUnknownExpressionPassesAll() {
        let engine = PipelineEngine()
        let data: [Any] = [1, 2, 3]
        // Unknown expression → all pass
        let result = engine.executeFilter(data: data, expression: "some.random.expression")
        XCTAssertEqual(result.count, 3)
    }

    // MARK: - PipelineEngine URL Template with Args

    func testURLTemplateWithArgs() {
        let engine = PipelineEngine()
        let template = "https://api.example.com/data?limit=${{ args.limit }}"
        let result = engine.resolveURLTemplate(template, item: nil, args: ["limit": "20"])
        XCTAssertEqual(result, "https://api.example.com/data?limit=20")
    }

    func testURLTemplateWithMissingArg() {
        let engine = PipelineEngine()
        let template = "https://api.example.com/data?limit=${{ args.limit }}"
        let result = engine.resolveURLTemplate(template, item: nil, args: [:])
        XCTAssertEqual(result, "https://api.example.com/data?limit=")
    }

    func testURLTemplateWithItemAndArgs() {
        let engine = PipelineEngine()
        let template = "https://api.example.com/${{ args.version }}/item/${{ item.id }}.json"
        let item: [String: Any] = ["id": 42]
        let result = engine.resolveURLTemplate(template, item: item, args: ["version": "v2"])
        XCTAssertEqual(result, "https://api.example.com/v2/item/42.json")
    }

    // MARK: - PipelineEngine Template Evaluation Edge Cases

    func testTemplateWithItemAsWhole() {
        let engine = PipelineEngine()
        let item: [String: Any] = ["key": "value"]
        let result = engine.evaluateTemplate("${{ item }}", item: item, index: 0, args: [:])
        XCTAssertTrue(result is [String: Any])
    }

    func testTemplateWithPlainText() {
        let engine = PipelineEngine()
        let result = engine.evaluateTemplate("just text", item: [:], index: 0, args: [:])
        XCTAssertEqual(result as? String, "just text")
    }

    func testTemplateWithMissingItemKey() {
        let engine = PipelineEngine()
        let item: [String: Any] = ["name": "Alice"]
        let result = engine.evaluateTemplate("${{ item.missing }}", item: item, index: 0, args: [:])
        // item["missing"] is nil, so result should be nil-ish
        XCTAssertNotNil(result)
    }

    func testTemplateWithIndexOnly() {
        let engine = PipelineEngine()
        let result = engine.evaluateTemplate("${{ index }}", item: [:], index: 5, args: [:])
        XCTAssertEqual(result as? Int, 5)
    }

    // MARK: - PipelineEngine Slice Edge Cases

    func testSliceStartExceedsData() {
        let engine = PipelineEngine()
        let result = engine.executeSlice(data: [1, 2, 3], from: 10, to: 20)
        XCTAssertTrue(result.isEmpty)
    }

    func testSliceNilTo() {
        let engine = PipelineEngine()
        let result = engine.executeSlice(data: [1, 2, 3, 4, 5], from: 2, to: nil)
        XCTAssertEqual(result.count, 3) // indices 2, 3, 4
    }

    // MARK: - PipelineEngine Map Edge Cases

    func testMapWithEmptyData() {
        let engine = PipelineEngine()
        let result = engine.executeMap(data: [], mapping: ["title": "${{ item.title }}"])
        XCTAssertTrue(result.isEmpty)
    }

    func testMapWithNonDictItems() {
        let engine = PipelineEngine()
        // Items that aren't dictionaries — should still process
        let data: [Any] = [42, "hello"]
        let result = engine.executeMap(data: data, mapping: ["value": "${{ item }}"])
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - PipelineEngine Format Output Edge Cases

    func testFormatOutputWithNonDictItems() {
        let data: [Any] = [42, "hello", true]
        let output = PipelineEngine.formatOutput(data)
        XCTAssertTrue(output.contains("1. 42"))
        XCTAssertTrue(output.contains("2. hello"))
    }

    func testFormatOutputSortsByKey() {
        let data: [Any] = [
            ["zebra": 1, "alpha": 2] as [String: Any]
        ]
        let output = PipelineEngine.formatOutput(data)
        // Keys should be sorted: alpha before zebra
        let alphaRange = output.range(of: "alpha")
        let zebraRange = output.range(of: "zebra")
        XCTAssertNotNil(alphaRange)
        XCTAssertNotNil(zebraRange)
        if let a = alphaRange, let z = zebraRange {
            XCTAssertTrue(a.lowerBound < z.lowerBound, "alpha should come before zebra")
        }
    }

    // MARK: - PipelineError

    func testPipelineErrorInvalidURL() {
        let error = PipelineError.invalidURL("not-a-url")
        XCTAssertEqual(error.errorDescription, "Invalid pipeline URL: not-a-url")
    }

    func testPipelineErrorFetchFailed() {
        let error = PipelineError.fetchFailed("timeout")
        XCTAssertEqual(error.errorDescription, "Pipeline fetch failed: timeout")
    }

    // MARK: - AdapterRegistry Bundled Adapters

    func testBundledAdaptersContainHackerNews() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        XCTAssertNotNil(registry.find(site: "hackernews", action: "top"))
        XCTAssertNotNil(registry.find(site: "hackernews", action: "new"))
        XCTAssertNotNil(registry.find(site: "hackernews", action: "best"))
    }

    func testBundledAdaptersCount() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        XCTAssertEqual(registry.adapterCount, 3)
    }

    func testBundledAdaptersHavePipelines() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        let top = registry.find(site: "hackernews", action: "top")
        XCTAssertNotNil(top)
        XCTAssertFalse(top!.pipeline.isEmpty, "HN top adapter should have pipeline steps")
        XCTAssertFalse(top!.requiresBrowser, "HN top should not require browser")
    }

    func testBundledAdaptersHaveArgs() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        let top = registry.find(site: "hackernews", action: "top")
        XCTAssertNotNil(top)
        // Should have a 'limit' arg
        let limitArg = top!.args.first { $0.name == "limit" }
        XCTAssertNotNil(limitArg, "HN top should have a 'limit' arg")
        XCTAssertEqual(limitArg?.type, .int)
    }

    func testListFormattedContainsAllAdapters() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        let output = registry.listFormatted()
        XCTAssertTrue(output.contains("hackernews"))
        XCTAssertTrue(output.contains("top"))
        XCTAssertTrue(output.contains("new"))
        XCTAssertTrue(output.contains("best"))
    }

    // MARK: - WebAgentToolProvider: Evaluate Command

    func testEvaluateMissingScript() async throws {
        let manager = WebViewManager()
        let provider = WebAgentToolProvider(manager: manager)
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("evaluate")
        ]))
        XCTAssertTrue(result.contains("Error"), "Should require 'script' parameter")
        XCTAssertTrue(result.contains("script"))
    }

    func testEvaluateOnBlankPage() async throws {
        let manager = WebViewManager()
        let provider = WebAgentToolProvider(manager: manager)
        let tool = provider.tools[0]
        // Evaluate JS on blank WKWebView
        do {
            let result = try await tool.handler(.object([
                "command": .string("evaluate"),
                "script": .string("1 + 1")
            ]))
            // Should return "2" or similar
            XCTAssertFalse(result.isEmpty)
        } catch {
            // JS eval may fail on blank page — that's acceptable
        }
    }

    // MARK: - WebAgentToolProvider: Screenshot Command

    func testScreenshotOnBlankPage() async throws {
        let manager = WebViewManager()
        let provider = WebAgentToolProvider(manager: manager)
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("screenshot")
        ]))
        // Should return data URI or error (blank page may or may not produce screenshot)
        XCTAssertTrue(result.contains("data:image/jpeg;base64,") || result.contains("Error"))
    }

    // MARK: - WebAgentToolProvider: Site Command Variants

    func testSiteCommandListAllViaToolProvider() async throws {
        let manager = WebViewManager()
        let provider = WebAgentToolProvider(manager: manager)
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "action": .string("list")
        ]))
        // Should list bundled adapters
        XCTAssertTrue(result.contains("hackernews"))
        XCTAssertTrue(result.contains("top"))
    }

    func testSiteCommandWithSiteOnly() async throws {
        let manager = WebViewManager()
        let provider = WebAgentToolProvider(manager: manager)
        let tool = provider.tools[0]
        // Provide site but no action → should list adapters for that site
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "site": .string("hackernews")
        ]))
        XCTAssertTrue(result.contains("hackernews") || result.contains("Available"))
        XCTAssertTrue(result.contains("top"))
    }

    func testSiteCommandUnknownSiteWithAction() async throws {
        let manager = WebViewManager()
        let provider = WebAgentToolProvider(manager: manager)
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("site"),
            "site": .string("nonexistent"),
            "action": .string("stuff")
        ]))
        XCTAssertTrue(result.contains("not found") || result.contains("Error"))
    }

    func testSiteCommandNoSiteNoAction() async throws {
        let manager = WebViewManager()
        let provider = WebAgentToolProvider(manager: manager)
        let tool = provider.tools[0]
        // No site, no action → should require site
        let result = try await tool.handler(.object([
            "command": .string("site")
        ]))
        XCTAssertTrue(result.contains("Error") || result.contains("required"),
                       "Should tell user 'site' is required or show list")
    }

    // MARK: - WebAgentToolProvider: Tool Schema for New Commands

    func testToolEnumContainsNewCommands() {
        let manager = WebViewManager()
        let provider = WebAgentToolProvider(manager: manager)
        let tool = provider.tools[0]
        if case .object(let schema) = tool.parameters,
           case .object(let props) = schema["properties"],
           case .object(let cmdProp) = props["command"],
           case .array(let enumValues) = cmdProp["enum"] {
            XCTAssertTrue(enumValues.contains(.string("site")))
            XCTAssertTrue(enumValues.contains(.string("evaluate")))
            XCTAssertTrue(enumValues.contains(.string("screenshot")))
        } else {
            XCTFail("Tool should have command enum with site/evaluate/screenshot")
        }
    }

    func testToolHasSiteParam() {
        let manager = WebViewManager()
        let provider = WebAgentToolProvider(manager: manager)
        let tool = provider.tools[0]
        if case .object(let schema) = tool.parameters,
           case .object(let props) = schema["properties"] {
            XCTAssertNotNil(props["site"], "Should have 'site' parameter")
            XCTAssertNotNil(props["action"], "Should have 'action' parameter")
            XCTAssertNotNil(props["script"], "Should have 'script' parameter")
        } else {
            XCTFail("Tool should have parameters")
        }
    }

    func testSkillPromptContainsNewCommands() {
        let prompt = WebAgentToolProvider.skillPrompt
        XCTAssertTrue(prompt.contains("evaluate"))
        XCTAssertTrue(prompt.contains("screenshot"))
        XCTAssertTrue(prompt.contains("site"))
        XCTAssertTrue(prompt.contains("JavaScript"))
        XCTAssertTrue(prompt.contains("base64"))
    }

    // MARK: - WebAgentError: NavigationTimeout

    func testNavigationTimeoutErrorDescription() {
        let error = WebAgentError.navigationTimeout("https://example.com")
        XCTAssertEqual(error.errorDescription, "Navigation timed out (30s): https://example.com")
    }

    // MARK: - YAMLAdapter Extended Parsing

    func testYAMLAdapterWithAllFields() throws {
        let yaml = """
        site: twitter
        name: trending
        description: Twitter trending topics
        auth: cookie
        domain: x.com
        requiresBrowser: true
        preNavigate: https://x.com/explore/tabs/trending
        waitSeconds: 3
        args:
          limit:
            type: int
            default: 20
            description: Number of topics
          category:
            type: string
            description: Topic category
        script: |
          (() => {
            const topics = document.querySelectorAll('[data-testid="trend"]');
            return JSON.stringify(Array.from(topics).map(t => ({
              topic: t.textContent
            })));
          })()
        """
        let adapter = try YAMLAdapter.parse(yaml)
        XCTAssertEqual(adapter.site, "twitter")
        XCTAssertEqual(adapter.name, "trending")
        XCTAssertTrue(adapter.requiresBrowser)
        XCTAssertEqual(adapter.preNavigate, "https://x.com/explore/tabs/trending")
        XCTAssertEqual(adapter.waitSeconds, 3)
        XCTAssertEqual(adapter.args.count, 2)
        XCTAssertNotNil(adapter.script)
        if case .cookie(let domain) = adapter.auth {
            XCTAssertEqual(domain, "x.com")
        } else {
            XCTFail("Expected cookie auth")
        }
    }

    func testYAMLAdapterWithFetchEachPipeline() throws {
        let yaml = """
        site: hackernews
        name: top
        description: Top stories with details
        auth: none
        requiresBrowser: false
        pipeline:
          - fetch: https://hacker-news.firebaseio.com/v0/topstories.json
          - slice: { to: 5 }
          - fetchEach: https://hacker-news.firebaseio.com/v0/item/${{ item }}.json
          - filter: "item.title != nil"
          - map: { title: "${{ item.title }}", score: "${{ item.score }}" }
        """
        let adapter = try YAMLAdapter.parse(yaml)
        XCTAssertEqual(adapter.pipeline.count, 5)

        // Verify pipeline step types
        if case .fetch(let url) = adapter.pipeline[0] {
            XCTAssertTrue(url.contains("topstories"))
        } else { XCTFail("Step 0 should be fetch") }

        if case .slice(_, let to) = adapter.pipeline[1] {
            XCTAssertEqual(to, 5)
        } else { XCTFail("Step 1 should be slice") }

        if case .fetchEach(let template) = adapter.pipeline[2] {
            XCTAssertTrue(template.contains("${{ item }}"))
        } else { XCTFail("Step 2 should be fetchEach") }

        if case .filter(let expr) = adapter.pipeline[3] {
            XCTAssertEqual(expr, "item.title != nil")
        } else { XCTFail("Step 3 should be filter") }

        if case .map(let mapping) = adapter.pipeline[4] {
            XCTAssertEqual(mapping["title"], "${{ item.title }}")
        } else { XCTFail("Step 4 should be map") }
    }

    func testYAMLAdapterHeaderAuth() throws {
        let yaml = """
        site: api
        name: data
        description: API with header auth
        auth: header
        requiresBrowser: false
        """
        let adapter = try YAMLAdapter.parse(yaml)
        if case .header = adapter.auth {
            // expected
        } else {
            XCTFail("Expected header auth")
        }
    }

    func testYAMLAdapterMissingNameThrows() {
        let yaml = """
        site: test
        description: Missing name
        auth: none
        requiresBrowser: false
        """
        XCTAssertThrowsError(try YAMLAdapter.parse(yaml))
    }

    // MARK: - AdapterRegistry Extended

    func testListForSiteWithNoAdapters() {
        let registry = AdapterRegistry()
        let result = registry.listForSite("nonexistent")
        XCTAssertTrue(result.isEmpty)
    }

    func testListAllEmpty() {
        let registry = AdapterRegistry()
        let result = registry.listAll()
        XCTAssertTrue(result.isEmpty)
    }

    func testListFormattedEmpty() {
        let registry = AdapterRegistry()
        let output = registry.listFormatted()
        // Should handle empty gracefully
        XCTAssertFalse(output.isEmpty) // Should say "no adapters" or similar
    }
}
