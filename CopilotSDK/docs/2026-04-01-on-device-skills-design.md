# On-Device Skills Discovery

**Date**: 2026-04-01  
**Status**: Approved  
**Scope**: CopilotSDK + Neox AgentCoordinator

## Problem

The desktop coding agent discovers skills from `.github/skills/*/SKILL.md` at runtime and lists them in the system prompt. The device has no skill discovery — tool providers are hardcoded at compile time. Users cannot extend the agent's capabilities with custom skills on their phone.

## Goal

Mirror the desktop skill system on-device: discover SKILL.md files in the phone's workspace, inject them into the system prompt, and let the agent read them via the existing `read_file` tool.

## Architecture

```
workspace/
  .github/
    skills/
      photo-editor/SKILL.md     ← skill file (YAML frontmatter + instructions)
      social-posting/SKILL.md   ← skill file
    agents/
      main.agent.md             ← agent profile (existing)
```

### New Types (CopilotSDK)

#### SkillDescriptor

Lightweight value type representing a discovered skill.

```swift
public struct SkillDescriptor: Sendable {
    public let name: String
    public let description: String
    /// Workspace-relative path (e.g., ".github/skills/photo-editor/SKILL.md")
    public let filePath: String
}
```

#### SkillDiscovery

Scans a workspace directory for SKILL.md files and parses their frontmatter.

```swift
public final class SkillDiscovery: Sendable {
    /// Discover skills in workspace/.github/skills/*/SKILL.md
    public func discover(in workspaceURL: URL) -> [SkillDescriptor]
}
```

**Discovery algorithm:**
1. List directories under `workspaceURL/.github/skills/`
2. For each directory, check for `SKILL.md`
3. Parse YAML frontmatter for `name` and `description` fields
4. Return `SkillDescriptor` with workspace-relative path
5. Skip entries with missing/invalid frontmatter (no crash, no error)

**Frontmatter format** (identical to desktop):

```yaml
---
name: photo-editor
description: Edit photos with filters, cropping, and adjustments
---

# Photo Editor Skill

Detailed instructions for the agent...
```

### Modified Types

#### AgentRuntimeProfile

Add `skills` property:

```swift
public struct AgentRuntimeProfile: Sendable {
    public let defaultModel: String?
    public let description: String?
    public let tools: [String]?
    public let preambleBody: String?
    public let sections: [String: SystemMessageSectionAction]
    public let skills: [SkillDescriptor]  // NEW
}
```

#### AgentProfileLoader.load()

After loading the profile, also call `SkillDiscovery.discover()`:

```swift
public func load(from workspaceURL: URL) throws -> AgentRuntimeProfile {
    // ... existing profile loading ...
    let skills = SkillDiscovery().discover(in: workspaceURL)
    return AgentRuntimeProfile(..., skills: skills)
}
```

### System Prompt Injection (Neox)

#### AgentCoordinator.buildSystemPrompt()

Append skills section if any skills are discovered:

```swift
func buildSystemPrompt() -> String {
    var prompt = "..." // existing prompt
    
    if let skills = agentProfile?.skills, !skills.isEmpty {
        prompt += "\n\n<instructions>\n"
        prompt += "Here is a list of skills on this phone that contain domain specific knowledge on a variety of topics.\n"
        prompt += "Each skill comes with a description of the topic and a file path that contains the detailed instructions.\n"
        prompt += "When a user asks you to perform a task that falls within the domain of a skill, use the 'read_file' tool to acquire the full instructions from the file path.\n"
        prompt += "<skills>\n"
        for skill in skills {
            prompt += "<skill>\n"
            prompt += "  <name>\(skill.name)</name>\n"
            prompt += "  <description>\(skill.description)</description>\n"
            prompt += "  <file>\(skill.filePath)</file>\n"
            prompt += "</skill>\n"
        }
        prompt += "</skills>\n"
        prompt += "</instructions>"
    }
    
    return prompt
}
```

## Data Flow

```
App launch
  → AgentProfileLoader.load(workspaceURL)
    → SkillDiscovery.discover(workspaceURL)
      → Scan .github/skills/*/SKILL.md
      → Parse frontmatter (name, description)
      → Return [SkillDescriptor]
    → AgentRuntimeProfile { ..., skills }
  → AgentCoordinator.buildSystemPrompt()
    → Append <skills> section
  → session.create(systemMessage: prompt, tools: [...])
  → Agent receives prompt with skill catalog

User asks: "edit my photo"
  → Agent matches "photo-editor" skill
  → Agent calls read_file(".github/skills/photo-editor/SKILL.md")
  → FileToolProvider resolves to workspace/.github/skills/photo-editor/SKILL.md
  → Agent receives full skill instructions
  → Agent follows skill instructions
```

## File Paths

File paths in the `<file>` tag are **workspace-relative** (e.g., `.github/skills/photo-editor/SKILL.md`). This works because `FileToolProvider` resolves all paths relative to the workspace root. The agent calls `read_file` with the same path and gets the file content.

## Error Handling

- Missing `.github/skills/` directory → empty skills array (no error)
- SKILL.md without valid frontmatter → silently skipped
- Missing `name` or `description` in frontmatter → silently skipped
- `SkillDiscovery.discover()` never throws

## Testing

1. **SkillDiscoveryTests** (CopilotSDK):
   - Discover skills from temp directory with valid SKILL.md files
   - Skip directories without SKILL.md
   - Skip SKILL.md without valid frontmatter
   - Handle empty skills directory
   - Handle missing .github/skills/ directory
   - Verify workspace-relative paths

2. **AgentProfileLoader integration**:
   - Profile loads skills alongside existing profile fields
   - Profile with no skills directory returns empty array

3. **AgentCoordinator integration** (Neox):
   - System prompt includes `<skills>` section when skills exist
   - System prompt omits section when no skills

## Scope Exclusions

- No skill installation/download UI (future work)
- No skill marketplace integration
- No dynamic tool registration from skills (skills are instructions, not code)
- No relay-side skill handling (device-side only)

## Files to Change

| File | Change |
|------|--------|
| `CopilotSDK/Sources/WorkspaceRuntime.swift` | Add `SkillDescriptor`, `SkillDiscovery`, modify `AgentRuntimeProfile` + `AgentProfileLoader` |
| `CopilotSDK/Tests/WorkspaceRuntimeTests.swift` | Add `SkillDiscoveryTests` |
| `Neox/Agent/AgentCoordinator.swift` | Modify `buildSystemPrompt()` to include skills |
| `NeoxTests/` (optional) | Integration test for skills in system prompt |
