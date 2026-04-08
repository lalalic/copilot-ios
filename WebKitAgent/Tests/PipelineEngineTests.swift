import XCTest
import Foundation
@testable import WebKitAgent

// MARK: - PipelineEngine Tests

@MainActor
final class PipelineEngineTests: XCTestCase {

    var engine: PipelineEngine!

    override func setUp() {
        super.setUp()
        engine = PipelineEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Slice

    func testSliceFromBeginning() async throws {
        let data: [Any] = [1, 2, 3, 4, 5]
        let result = engine.executeSlice(data: data, from: 0, to: 3)
        XCTAssertEqual(result.count, 3)
    }

    func testSliceWithFrom() async throws {
        let data: [Any] = [1, 2, 3, 4, 5]
        let result = engine.executeSlice(data: data, from: 2, to: nil)
        XCTAssertEqual(result.count, 3) // items at index 2, 3, 4
    }

    func testSliceToExceedingCount() async throws {
        let data: [Any] = [1, 2, 3]
        let result = engine.executeSlice(data: data, from: 0, to: 100)
        XCTAssertEqual(result.count, 3)
    }

    func testSliceEmpty() async throws {
        let data: [Any] = []
        let result = engine.executeSlice(data: data, from: 0, to: 5)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Filter

    func testFilterByKeyExists() async throws {
        let data: [Any] = [
            ["title": "hello", "deleted": false] as [String: Any],
            ["title": "world", "deleted": true] as [String: Any],
            ["deleted": true] as [String: Any]
        ]
        let result = engine.executeFilter(data: data, expression: "item.title != nil")
        XCTAssertEqual(result.count, 2)
    }

    func testFilterEmptyData() async throws {
        let data: [Any] = []
        let result = engine.executeFilter(data: data, expression: "item.title != nil")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Map

    func testMapExtractFields() async throws {
        let data: [Any] = [
            ["title": "Post 1", "score": 100, "by": "user1"] as [String: Any],
            ["title": "Post 2", "score": 200, "by": "user2"] as [String: Any]
        ]
        let mapping: [String: String] = [
            "title": "${{ item.title }}",
            "author": "${{ item.by }}"
        ]
        let result = engine.executeMap(data: data, mapping: mapping)
        XCTAssertEqual(result.count, 2)
        if let first = result[0] as? [String: Any] {
            XCTAssertEqual(first["title"] as? String, "Post 1")
            XCTAssertEqual(first["author"] as? String, "user1")
        } else {
            XCTFail("Expected dictionary")
        }
    }

    func testMapWithIndex() async throws {
        let data: [Any] = [
            ["title": "A"] as [String: Any],
            ["title": "B"] as [String: Any]
        ]
        let mapping: [String: String] = [
            "rank": "${{ index + 1 }}"
        ]
        let result = engine.executeMap(data: data, mapping: mapping)
        if let first = result[0] as? [String: Any],
           let second = result[1] as? [String: Any] {
            XCTAssertEqual(first["rank"] as? Int, 1)
            XCTAssertEqual(second["rank"] as? Int, 2)
        } else {
            XCTFail("Expected dictionaries")
        }
    }

    // MARK: - Template Evaluation

    func testTemplateSimpleProperty() {
        let item: [String: Any] = ["name": "Alice"]
        let result = engine.evaluateTemplate("${{ item.name }}", item: item, index: 0, args: [:])
        XCTAssertEqual(result as? String, "Alice")
    }

    func testTemplateNumericProperty() {
        let item: [String: Any] = ["score": 42]
        let result = engine.evaluateTemplate("${{ item.score }}", item: item, index: 0, args: [:])
        XCTAssertEqual(result as? Int, 42)
    }

    func testTemplateIndexExpression() {
        let item: [String: Any] = [:]
        let result = engine.evaluateTemplate("${{ index + 1 }}", item: item, index: 3, args: [:])
        XCTAssertEqual(result as? Int, 4)
    }

    func testTemplateArgReference() {
        let item: [String: Any] = [:]
        let args: [String: String] = ["limit": "10"]
        let result = engine.evaluateTemplate("${{ args.limit }}", item: item, index: 0, args: args)
        XCTAssertEqual(result as? String, "10")
    }

    func testTemplateNoMatch() {
        let result = engine.evaluateTemplate("plain text", item: [:], index: 0, args: [:])
        XCTAssertEqual(result as? String, "plain text")
    }

    // MARK: - URL Template

    func testURLTemplateSubstitution() {
        let template = "https://api.example.com/item/${{ item }}.json"
        let result = engine.resolveURLTemplate(template, item: 12345, args: [:])
        XCTAssertEqual(result, "https://api.example.com/item/12345.json")
    }

    func testURLTemplateWithItemProperty() {
        let template = "https://api.example.com/item/${{ item.id }}.json"
        let item: [String: Any] = ["id": 67890]
        let result = engine.resolveURLTemplate(template, item: item, args: [:])
        XCTAssertEqual(result, "https://api.example.com/item/67890.json")
    }

    // MARK: - Format Output

    func testFormatOutputAsList() {
        let data: [Any] = [
            ["title": "Hello", "score": 10] as [String: Any],
            ["title": "World", "score": 20] as [String: Any]
        ]
        let output = PipelineEngine.formatOutput(data)
        XCTAssertTrue(output.contains("Hello"))
        XCTAssertTrue(output.contains("World"))
        XCTAssertTrue(output.contains("10"))
    }

    func testFormatOutputEmpty() {
        let output = PipelineEngine.formatOutput([])
        XCTAssertTrue(output.contains("No results"))
    }

    // MARK: - Extract

    func testExtractNestedPath() {
        let engine = PipelineEngine()
        let data: [Any] = [
            ["data": ["children": [
                ["data": ["title": "Post 1", "score": 42]],
                ["data": ["title": "Post 2", "score": 99]]
            ]]] as [String: Any]
        ]
        // Extract data.children
        let step1 = engine.executeExtract(data: data, path: "data.children")
        XCTAssertEqual(step1.count, 2)
        // Extract data from each child
        let step2 = engine.executeExtract(data: step1, path: "data")
        XCTAssertEqual(step2.count, 2)
        if let first = step2[0] as? [String: Any] {
            XCTAssertEqual(first["title"] as? String, "Post 1")
            XCTAssertEqual(first["score"] as? Int, 42)
        } else {
            XCTFail("Expected dictionary")
        }
    }

    func testExtractMissingPath() {
        let engine = PipelineEngine()
        let data: [Any] = [["name": "test"] as [String: Any]]
        let result = engine.executeExtract(data: data, path: "data.missing")
        XCTAssertEqual(result.count, 0)
    }

    func testNestedTemplateEvaluation() {
        let engine = PipelineEngine()
        let item: [String: Any] = ["data": ["title": "Nested", "author": "bob"]]
        let result = engine.evaluateTemplate("${{ item.data.title }}", item: item, index: 0, args: [:])
        XCTAssertEqual(result as? String, "Nested")
    }
}
