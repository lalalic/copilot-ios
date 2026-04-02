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

    // MARK: - Skill Discovery

    func testDiscoverFindsValidSkills() throws {
        let workspace = try makeWorkspace()
        let skillsDir = workspace.appendingPathComponent(".github/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir.appendingPathComponent("photo-editor"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsDir.appendingPathComponent("music-gen"), withIntermediateDirectories: true)

        try """
        ---
        name: photo-editor
        description: Edit photos with filters and crops
        ---
        # Photo Editor Skill
        Use the camera tool to capture...
        """.write(to: skillsDir.appendingPathComponent("photo-editor/SKILL.md"), atomically: true, encoding: .utf8)

        try """
        ---
        name: music-gen
        description: "Generate music from text prompts"
        ---
        # Music Generation
        Use the speak tool...
        """.write(to: skillsDir.appendingPathComponent("music-gen/SKILL.md"), atomically: true, encoding: .utf8)

        let skills = SkillDiscovery().discover(in: workspace)

        XCTAssertEqual(skills.count, 2)
        // Sorted alphabetically
        XCTAssertEqual(skills[0].name, "music-gen")
        XCTAssertEqual(skills[0].description, "Generate music from text prompts")
        XCTAssertEqual(skills[0].filePath, ".github/skills/music-gen/SKILL.md")
        XCTAssertEqual(skills[1].name, "photo-editor")
        XCTAssertEqual(skills[1].description, "Edit photos with filters and crops")
        XCTAssertEqual(skills[1].filePath, ".github/skills/photo-editor/SKILL.md")
    }

    func testDiscoverSkipsMissingSkillFile() throws {
        let workspace = try makeWorkspace()
        let skillsDir = workspace.appendingPathComponent(".github/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir.appendingPathComponent("empty-skill"), withIntermediateDirectories: true)
        // No SKILL.md created

        let skills = SkillDiscovery().discover(in: workspace)
        XCTAssertTrue(skills.isEmpty)
    }

    func testDiscoverSkipsInvalidFrontmatter() throws {
        let workspace = try makeWorkspace()
        let skillsDir = workspace.appendingPathComponent(".github/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir.appendingPathComponent("bad-skill"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsDir.appendingPathComponent("no-desc"), withIntermediateDirectories: true)

        // No frontmatter at all
        try "# Just markdown\nNo frontmatter".write(
            to: skillsDir.appendingPathComponent("bad-skill/SKILL.md"), atomically: true, encoding: .utf8)

        // Missing description
        try """
        ---
        name: no-desc
        ---
        Body
        """.write(to: skillsDir.appendingPathComponent("no-desc/SKILL.md"), atomically: true, encoding: .utf8)

        let skills = SkillDiscovery().discover(in: workspace)
        XCTAssertTrue(skills.isEmpty)
    }

    func testDiscoverReturnsEmptyForMissingDirectory() throws {
        let workspace = try makeWorkspace()
        // .github/skills/ does not exist
        let skills = SkillDiscovery().discover(in: workspace)
        XCTAssertTrue(skills.isEmpty)
    }

    func testProfileLoaderIncludesSkills() throws {
        let workspace = try makeWorkspace()
        let skillsDir = workspace.appendingPathComponent(".github/skills/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        try """
        ---
        name: demo
        description: A demo skill
        ---
        Instructions here
        """.write(to: skillsDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let agentFile = workspace.appendingPathComponent(".github/agents/main.agent.md")
        try """
        ---
        model: gpt-4.1
        ---
        Preamble
        """.write(to: agentFile, atomically: true, encoding: .utf8)

        let profile = try AgentProfileLoader().load(from: workspace)
        XCTAssertEqual(profile.skills.count, 1)
        XCTAssertEqual(profile.skills[0].name, "demo")
        XCTAssertEqual(profile.skills[0].filePath, ".github/skills/demo/SKILL.md")
    }

    func testProfileLoaderReturnsSkillsEvenWithoutAgentFile() throws {
        let workspace = try makeWorkspace()
        let skillsDir = workspace.appendingPathComponent(".github/skills/solo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        try """
        ---
        name: solo
        description: Solo skill with no agent profile
        ---
        Body
        """.write(to: skillsDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // Remove the agent file (makeWorkspace creates .github/agents/ but no file)
        let profile = try AgentProfileLoader().load(from: workspace)
        XCTAssertEqual(profile.skills.count, 1)
        XCTAssertEqual(profile.skills[0].name, "solo")
    }
}
