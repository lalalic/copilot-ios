import XCTest
@testable import CopilotSDK

final class FileToolProviderTests: XCTestCase {
    
    var tmpDir: URL!
    var provider: FileToolProvider!
    
    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileToolProviderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        provider = FileToolProvider(baseDirectory: tmpDir)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }
    
    // MARK: - create_project
    
    func testCreateProjectBasic() async throws {
        let tool = provider.tools.first { $0.name == "create_project" }
        XCTAssertNotNil(tool, "create_project tool should exist")
        
        let result = try await tool!.handler(.object([
            "name": .string("TestApp")
        ]))
        
        XCTAssertTrue(result.contains("Created project 'TestApp'"))
        
        // Verify folder structure
        let projectDir = tmpDir.appendingPathComponent("TestApp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("docs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("progress").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("README.md").path))
    }
    
    func testCreateProjectWithAllParams() async throws {
        let tool = provider.tools.first { $0.name == "create_project" }!
        
        let result = try await tool.handler(.object([
            "name": .string("FitnessTracker"),
            "description": .string("Track daily workouts"),
            "goal": .string("Help users log exercises and see progress"),
            "features": .array([
                .string("Log exercises"),
                .string("Daily summary"),
                .string("Weekly charts")
            ])
        ]))
        
        XCTAssertTrue(result.contains("Created project 'FitnessTracker'"))
        
        // Verify README content
        let readme = try String(contentsOf: tmpDir.appendingPathComponent("FitnessTracker/README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("name: FitnessTracker"))
        XCTAssertTrue(readme.contains("description: Track daily workouts"))
        XCTAssertTrue(readme.contains("Help users log exercises and see progress"))
        XCTAssertTrue(readme.contains("- [ ] Log exercises"))
        XCTAssertTrue(readme.contains("- [ ] Daily summary"))
        XCTAssertTrue(readme.contains("- [ ] Weekly charts"))
    }
    
    func testCreateProjectFromTemplate() async throws {
        // Set up a custom template
        let templateDir = tmpDir
            .appendingPathComponent(".templates/projects/custom-app", isDirectory: true)
        try FileManager.default.createDirectory(at: templateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: templateDir.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "# Template README".write(
            to: templateDir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )
        
        let tool = provider.tools.first { $0.name == "create_project" }!
        let result = try await tool.handler(.object([
            "name": .string("MyApp"),
            "template": .string("custom-app")
        ]))
        
        XCTAssertTrue(result.contains("template 'custom-app'"))
        
        // Template's assets/ folder should be copied
        let assetsDir = tmpDir.appendingPathComponent("MyApp/assets")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetsDir.path))
        
        // README should be overwritten with generated content (not template's)
        let readme = try String(contentsOf: tmpDir.appendingPathComponent("MyApp/README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("name: MyApp"))
    }
    
    func testCreateProjectDuplicate() async throws {
        let tool = provider.tools.first { $0.name == "create_project" }!
        
        _ = try await tool.handler(.object(["name": .string("Dup")]))
        let result = try await tool.handler(.object(["name": .string("Dup")]))
        
        XCTAssertTrue(result.contains("Error: project already exists"))
    }
    
    func testCreateProjectInvalidName() async throws {
        let tool = provider.tools.first { $0.name == "create_project" }!
        
        let result1 = try await tool.handler(.object(["name": .string("../../escape")]))
        XCTAssertTrue(result1.contains("Error: invalid project name"))
        
        let result2 = try await tool.handler(.object(["name": .string("path/traversal")]))
        XCTAssertTrue(result2.contains("Error: invalid project name"))
        
        let result3 = try await tool.handler(.object(["name": .string("")]))
        XCTAssertTrue(result3.contains("Error: project name cannot be empty"))
    }
    
    func testCreateProjectMissingName() async throws {
        let tool = provider.tools.first { $0.name == "create_project" }!
        
        let result = try await tool.handler(.object([:]))
        XCTAssertTrue(result.contains("Error: 'name' (string) required"))
    }
}
