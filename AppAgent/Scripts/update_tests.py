import os

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Tests', 'AppAgentTests.swift')
with open(path, 'r') as f:
    content = f.read()

# Update command enum test to include pick
content = content.replace(
    '"scroll_to"]',
    '"scroll_to", "pick"]'
)

# Update skill prompt test to include pick
content = content.replace(
    'for cmd in ["snapshot", "tap", "type", "swipe", "long_press", "find", "scroll_to", "screenshot"]',
    'for cmd in ["snapshot", "tap", "type", "swipe", "long_press", "find", "scroll_to", "pick", "screenshot"]'
)

# Add pick validation test
pick_test = '''
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
'''

content = content.rstrip()
if content.endswith('}'):
    content = content[:-1] + pick_test

with open(path, 'w') as f:
    f.write(content)
print('Updated AppAgentTests.swift')
