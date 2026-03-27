import XCTest
@testable import AppAgent

/// AppAgent tests — unit tests for component logic.
/// Note: Full UI testing requires running in an iOS app context.
/// These tests verify data structures, tool schemas, and non-UI logic.
final class AppAgentTests: XCTestCase {

    // MARK: - AppElement

    func testAppElementDescription() {
        let element = AppElement(
            ref: "r0",
            kind: "button",
            label: "Submit",
            value: nil,
            isEnabled: true,
            isSelected: false,
            frame: CGRect(x: 0, y: 0, width: 100, height: 44),
            traits: "button"
        )
        XCTAssertEqual(element.description, "r0 [button] \"Submit\"")
    }

    func testAppElementDescriptionWithValue() {
        let element = AppElement(
            ref: "r3",
            kind: "textField",
            label: "Username",
            value: "john",
            isEnabled: true,
            isSelected: false,
            frame: CGRect(x: 0, y: 0, width: 200, height: 44),
            traits: "search"
        )
        XCTAssertEqual(element.description, "r3 [textField] \"Username\" value=\"john\"")
    }

    func testAppElementDescriptionDisabled() {
        let element = AppElement(
            ref: "r1",
            kind: "button",
            label: "Next",
            value: nil,
            isEnabled: false,
            isSelected: false,
            frame: CGRect(x: 0, y: 0, width: 100, height: 44),
            traits: "button"
        )
        XCTAssertTrue(element.description.contains("(disabled)"))
    }

    func testAppElementDescriptionSelected() {
        let element = AppElement(
            ref: "r5",
            kind: "button",
            label: "Home",
            value: nil,
            isEnabled: true,
            isSelected: true,
            frame: CGRect(x: 0, y: 0, width: 80, height: 44),
            traits: "button,selected"
        )
        XCTAssertTrue(element.description.contains("(selected)"))
    }

    func testAppElementDescriptionSwitchOn() {
        let element = AppElement(
            ref: "r2",
            kind: "switch",
            label: "Dark Mode",
            value: "on",
            isEnabled: true,
            isSelected: false,
            frame: CGRect(x: 0, y: 0, width: 51, height: 31),
            traits: "button"
        )
        XCTAssertEqual(element.description, "r2 [switch] \"Dark Mode\" value=\"on\"")
    }

    func testAppElementEmptyLabel() {
        let element = AppElement(
            ref: "r0",
            kind: "view",
            label: "",
            value: nil,
            isEnabled: true,
            isSelected: false,
            frame: CGRect(x: 0, y: 0, width: 50, height: 50),
            traits: ""
        )
        XCTAssertEqual(element.description, "r0 [view]")
    }

    func testAppElementEmptyValue() {
        let element = AppElement(
            ref: "r1",
            kind: "textField",
            label: "Name",
            value: "",
            isEnabled: true,
            isSelected: false,
            frame: CGRect(x: 0, y: 0, width: 200, height: 44),
            traits: ""
        )
        // Empty value should not be shown
        XCTAssertEqual(element.description, "r1 [textField] \"Name\"")
    }

    // MARK: - Tool Provider Schema

    @MainActor
    func testToolProviderHasOneToolOnIOS() {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        XCTAssertEqual(provider.tools.count, 1)
        XCTAssertEqual(provider.tools[0].name, "app_agent")
        #endif
    }

    @MainActor
    func testToolRequiresCommand() {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        if case .object(let schema) = tool.parameters,
           case .array(let required) = schema["required"] {
            XCTAssertTrue(required.contains(.string("command")))
        } else {
            XCTFail("Tool should require 'command'")
        }
        #endif
    }

    @MainActor
    func testToolHasCommandEnum() {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        if case .object(let schema) = tool.parameters,
           case .object(let props) = schema["properties"],
           case .object(let cmdProp) = props["command"],
           case .array(let enumValues) = cmdProp["enum"] {
            XCTAssertTrue(enumValues.contains(.string("snapshot")))
            XCTAssertTrue(enumValues.contains(.string("tap")))
            XCTAssertTrue(enumValues.contains(.string("type")))
            XCTAssertTrue(enumValues.contains(.string("screenshot")))
            XCTAssertTrue(enumValues.contains(.string("swipe")))
            XCTAssertTrue(enumValues.contains(.string("long_press")))
            XCTAssertTrue(enumValues.contains(.string("find")))
            XCTAssertTrue(enumValues.contains(.string("scroll_to")))
        } else {
            XCTFail("command property should have enum values")
        }
        #endif
    }

    @MainActor
    func testSkillPromptContainsAllCommands() {
        #if os(iOS)
        let prompt = AppAgentToolProvider.skillPrompt
        XCTAssertTrue(prompt.contains("snapshot"))
        XCTAssertTrue(prompt.contains("tap"))
        XCTAssertTrue(prompt.contains("type"))
        XCTAssertTrue(prompt.contains("screenshot"))
        XCTAssertTrue(prompt.contains("swipe"))
        XCTAssertTrue(prompt.contains("long_press"))
        XCTAssertTrue(prompt.contains("find"))
        XCTAssertTrue(prompt.contains("scroll_to"))
        XCTAssertTrue(prompt.contains("app_agent"))
        #endif
    }

    @MainActor
    func testRejectsUnknownCommand() async throws {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        let result = try await tool.handler(.object(["command": .string("fly")]))
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("unknown command"))
        #endif
    }

    @MainActor
    func testRejectsNullArgs() async throws {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        let result = try await tool.handler(.null)
        XCTAssertTrue(result.contains("Error"))
        #endif
    }

    @MainActor
    func testTapRequiresRef() async throws {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        let result = try await tool.handler(.object(["command": .string("tap")]))
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("ref"))
        #endif
    }

    @MainActor
    func testTypeRequiresRefAndText() async throws {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("type"),
            "ref": .string("r0")
        ]))
        XCTAssertTrue(result.contains("Error"))
        #endif
    }

    @MainActor
    func testSwipeRequiresDirection() async throws {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("swipe")
        ]))
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("direction"))
        #endif
    }

    @MainActor
    func testLongPressRequiresRef() async throws {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("long_press")
        ]))
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("ref"))
        #endif
    }

    @MainActor
    func testFindRequiresText() async throws {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("find")
        ]))
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("text"))
        #endif
    }

    @MainActor
    func testScrollToRequiresRef() async throws {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("scroll_to")
        ]))
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("ref"))
        #endif
    }

    @MainActor
    func testPickRequiresRefAndValue() async throws {
        #if os(iOS)
        let provider = AppAgentToolProvider()
        let tool = provider.tools[0]
        let result = try await tool.handler(.object([
            "command": .string("pick"),
            "ref": .string("r0")
        ]))
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("value"))
        #endif
    }

}
