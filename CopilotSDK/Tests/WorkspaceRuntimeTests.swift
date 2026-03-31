import XCTest
@testable import CopilotSDK

final class WorkspaceRuntimeTests: XCTestCase {

    func testAgentProfileLoaderParsesRelayStyleFrontmatterAndSections() throws {
        let workspace = try makeWorkspace()
        let agentFile = workspace
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("main.agent.md")

        let content = """
        ---
        model: gpt-5
        description: Demo profile
        tools: [ffmpeg, read_file]
        ---
        This is preamble.

        # Core Behavior
        Follow project standards.

        # Safety
        Never expose secrets.
        """
        try content.write(to: agentFile, atomically: true, encoding: .utf8)

        let profile = try AgentProfileLoader().load(from: workspace)

        XCTAssertEqual(profile.defaultModel, "gpt-5")
        XCTAssertEqual(profile.description, "Demo profile")
        XCTAssertEqual(profile.tools ?? [], ["ffmpeg", "read_file"])
        XCTAssertEqual(profile.preambleBody, "This is preamble.")

        guard case .replace(let guidelines)? = profile.sections["guidelines"] else {
            return XCTFail("Expected guidelines replace action")
        }
        XCTAssertEqual(guidelines, "Follow project standards.")

        guard case .replace(let safety)? = profile.sections["safety"] else {
            return XCTFail("Expected safety replace action")
        }
        XCTAssertEqual(safety, "Never expose secrets.")
    }

    func testAgentProfileLoaderFallsBackToRawBodyWithoutFrontmatter() throws {
        let workspace = try makeWorkspace()
        let agentFile = workspace
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("main.agent.md")

        let content = """
        plain body only
        no frontmatter
        """
        try content.write(to: agentFile, atomically: true, encoding: .utf8)

        let profile = try AgentProfileLoader().load(from: workspace)

        XCTAssertNil(profile.defaultModel)
        XCTAssertEqual(profile.preambleBody, "plain body only\nno frontmatter")
        XCTAssertTrue(profile.sections.isEmpty)
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".github/agents", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }
}
