import XCTest
@testable import CopilotSDK

final class MemoryToolProviderTests: XCTestCase {

    func testMemoryAppendAndRead() async throws {
        let workspace = try makeWorkspace()
        let provider = MemoryToolProvider(baseDirectory: workspace)

        let append = try tool(named: "memory_append", from: provider)
        _ = try await append.handler(.object([
            "content": .string("First memory note")
        ]))

        let read = try tool(named: "memory_read", from: provider)
        let content = try await read.handler(.object([:]))

        XCTAssertTrue(content.contains("First memory note"))
        XCTAssertTrue(content.contains("# memory"))
    }

    func testMemoryWriteSectionAndSectionRead() async throws {
        let workspace = try makeWorkspace()
        let provider = MemoryToolProvider(baseDirectory: workspace)

        let writeSection = try tool(named: "memory_write_section", from: provider)
        _ = try await writeSection.handler(.object([
            "section": .string("lessons"),
            "content": .string("Always keep memory updates concise.")
        ]))

        let read = try tool(named: "memory_read", from: provider)
        let section = try await read.handler(.object([
            "section": .string("lessons")
        ]))

        XCTAssertTrue(section.contains("## lessons"))
        XCTAssertTrue(section.contains("Always keep memory updates concise."))
    }

    func testSessionLogCreatesReportAndListFindsIt() async throws {
        let workspace = try makeWorkspace()
        let provider = MemoryToolProvider(baseDirectory: workspace)

        let logSession = try tool(named: "memory_log_session", from: provider)
        let result = try await logSession.handler(.object([
            "topic": .string("memory-tools"),
            "summary": .string("Added full memory provider design and implementation.")
        ]))
        XCTAssertTrue(result.contains(".neo/reports/sessions/"))

        let list = try tool(named: "memory_list", from: provider)
        let output = try await list.handler(.object([
            "path": .string(".neo/reports/sessions")
        ]))

        XCTAssertTrue(output.contains("memory-tools"))
    }

    func testProjectMemoryReadWrite() async throws {
        let workspace = try makeWorkspace()
        let provider = MemoryToolProvider(baseDirectory: workspace)

        // Create project directory
        let projectDir = workspace.appendingPathComponent("test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Write section to project memory
        let writeSection = try tool(named: "memory_write_section", from: provider)
        _ = try await writeSection.handler(.object([
            "section": .string("contacts"),
            "content": .string("- Alice: project lead\n- Bob: designer"),
            "path": .string("test-project/memory.md")
        ]))

        // Read it back
        let read = try tool(named: "memory_read", from: provider)
        let content = try await read.handler(.object([
            "path": .string("test-project/memory.md")
        ]))
        XCTAssertTrue(content.contains("## contacts"))
        XCTAssertTrue(content.contains("Alice: project lead"))

        // Append to project memory
        let append = try tool(named: "memory_append", from: provider)
        _ = try await append.handler(.object([
            "content": .string("Project deadline moved to Friday"),
            "path": .string("test-project/memory.md")
        ]))

        let updated = try await read.handler(.object([
            "path": .string("test-project/memory.md")
        ]))
        XCTAssertTrue(updated.contains("Project deadline moved to Friday"))
        XCTAssertTrue(updated.contains("## contacts")) // original section preserved

        // Search within project
        let search = try tool(named: "memory_search", from: provider)
        let results = try await search.handler(.object([
            "query": .string("alice"),
            "path": .string("test-project")
        ]))
        XCTAssertTrue(results.contains("memory.md"))
    }

    private func tool(named name: String, from provider: MemoryToolProvider) throws -> ToolDefinition {
        guard let tool = provider.tools.first(where: { $0.name == name }) else {
            throw NSError(domain: "MemoryToolProviderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tool not found: \(name)"])
        }
        return tool
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
