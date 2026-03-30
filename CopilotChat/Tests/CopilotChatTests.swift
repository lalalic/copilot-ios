import Testing
@testable import CopilotChat

@Test func chatMessageParsing() {
    let blocks = parseContentBlocks("Hello **world**")
    #expect(!blocks.isEmpty)
}

@Test func todoItemStatus() {
    let item = TodoItem(id: 1, title: "Test", status: .inProgress)
    #expect(item.statusIcon == "●")
}
