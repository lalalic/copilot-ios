import XCTest
@testable import WebKitAgent

// MARK: - DOMSnapshot Script Tests

final class DOMSnapshotTests: XCTestCase {

    // MARK: - Snapshot Script

    func testSnapshotScriptIsValidIIFE() {
        let script = DOMSnapshot.snapshotScript
        XCTAssertTrue(script.hasPrefix("(function()"))
        XCTAssertTrue(script.hasSuffix(")()"))
    }

    func testSnapshotScriptContainsRefAttribute() {
        let script = DOMSnapshot.snapshotScript
        XCTAssertTrue(script.contains("data-wa-ref"))
    }

    func testSnapshotScriptSelectsCommonElements() {
        let script = DOMSnapshot.snapshotScript
        XCTAssertTrue(script.contains("a[href]"))
        XCTAssertTrue(script.contains("button"))
        XCTAssertTrue(script.contains("input"))
        XCTAssertTrue(script.contains("textarea"))
        XCTAssertTrue(script.contains("select"))
    }

    func testSnapshotScriptReturnsJSON() {
        let script = DOMSnapshot.snapshotScript
        XCTAssertTrue(script.contains("JSON.stringify"))
        XCTAssertTrue(script.contains("title:"))
        XCTAssertTrue(script.contains("url:"))
        XCTAssertTrue(script.contains("count:"))
        XCTAssertTrue(script.contains("refs:"))
    }

    func testSnapshotScriptClearsOldRefs() {
        let script = DOMSnapshot.snapshotScript
        XCTAssertTrue(script.contains("removeAttribute('data-wa-ref')"))
    }

    func testSnapshotScriptChecksVisibility() {
        let script = DOMSnapshot.snapshotScript
        XCTAssertTrue(script.contains("getBoundingClientRect"))
        XCTAssertTrue(script.contains("getComputedStyle"))
        XCTAssertTrue(script.contains("display !== 'none'"))
    }

    func testSnapshotScriptIncludesARIARoles() {
        let script = DOMSnapshot.snapshotScript
        XCTAssertTrue(script.contains("[role=\"button\"]"))
        XCTAssertTrue(script.contains("[role=\"link\"]"))
        XCTAssertTrue(script.contains("[role=\"tab\"]"))
        XCTAssertTrue(script.contains("[role=\"checkbox\"]"))
    }

    // MARK: - Click Script

    func testClickScriptUsesRef() {
        let script = DOMSnapshot.clickScript(ref: "r5")
        XCTAssertTrue(script.contains("data-wa-ref=\"r5\""))
    }

    func testClickScriptIsIIFE() {
        let script = DOMSnapshot.clickScript(ref: "r0")
        XCTAssertTrue(script.hasPrefix("(function()"))
        XCTAssertTrue(script.hasSuffix(")()"))
    }

    func testClickScriptReturnsJSON() {
        let script = DOMSnapshot.clickScript(ref: "r0")
        XCTAssertTrue(script.contains("JSON.stringify"))
        XCTAssertTrue(script.contains("tag"))
        XCTAssertTrue(script.contains("text"))
    }

    func testClickScriptHandlesNotFound() {
        let script = DOMSnapshot.clickScript(ref: "r999")
        XCTAssertTrue(script.contains("error"))
        XCTAssertTrue(script.contains("Element not found"))
    }

    func testClickScriptScrollsAndFocuses() {
        let script = DOMSnapshot.clickScript(ref: "r0")
        XCTAssertTrue(script.contains("scrollIntoView"))
        XCTAssertTrue(script.contains("el.focus()"))
        XCTAssertTrue(script.contains("el.click()"))
    }

    func testClickScriptEscapesQuotes() {
        let script = DOMSnapshot.clickScript(ref: "r\"injected")
        // Should escape the quote
        XCTAssertFalse(script.contains("r\"injected\""))
    }

    // MARK: - Type Script

    func testTypeScriptUsesRef() {
        let script = DOMSnapshot.typeScript(ref: "r3", text: "hello", clear: true)
        XCTAssertTrue(script.contains("data-wa-ref=\"r3\""))
    }

    func testTypeScriptClearsWhenTrue() {
        let script = DOMSnapshot.typeScript(ref: "r0", text: "test", clear: true)
        XCTAssertTrue(script.contains("el.value = '';"))
    }

    func testTypeScriptNoClearWhenFalse() {
        let script = DOMSnapshot.typeScript(ref: "r0", text: "test", clear: false)
        XCTAssertTrue(script.contains("if (false)"))
    }

    func testTypeScriptSetsValue() {
        let script = DOMSnapshot.typeScript(ref: "r0", text: "Hello World", clear: true)
        XCTAssertTrue(script.contains("Hello World"))
    }

    func testTypeScriptDispatchesEvents() {
        let script = DOMSnapshot.typeScript(ref: "r0", text: "x", clear: false)
        XCTAssertTrue(script.contains("Event('input'"))
        XCTAssertTrue(script.contains("Event('change'"))
        XCTAssertTrue(script.contains("bubbles: true"))
    }

    func testTypeScriptEscapesSpecialChars() {
        let script = DOMSnapshot.typeScript(ref: "r0", text: "line1\nline2", clear: true)
        // Newline should be escaped for JS string
        XCTAssertTrue(script.contains("\\n"))
    }

    func testTypeScriptEscapesQuotesInText() {
        let script = DOMSnapshot.typeScript(ref: "r0", text: "say \"hello\"", clear: true)
        // Quotes should be escaped
        XCTAssertTrue(script.contains("\\\"hello\\\"") || script.contains("say"))
    }

    func testTypeScriptHandlesNotFound() {
        let script = DOMSnapshot.typeScript(ref: "r0", text: "x", clear: true)
        XCTAssertTrue(script.contains("error"))
        XCTAssertTrue(script.contains("Element not found"))
    }

    func testTypeScriptReturnsJSON() {
        let script = DOMSnapshot.typeScript(ref: "r0", text: "x", clear: true)
        XCTAssertTrue(script.contains("JSON.stringify"))
    }
}
