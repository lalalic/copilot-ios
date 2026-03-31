# Device Workspace Bootstrap + Agent Profile Loading (Neox First)

## Context

Neox currently:
- Uses on-device file/media tools that assume a workspace directory.
- Hardcodes system prompt/model behavior in app code.
- Does not provision a monorepo workspace seed into `Library/Application Support`.

Goal:
- Create a shared component pattern (Neox first) to provision an app workspace on device.
- Parse `.github/agents/main.agent.md` with relay-compatible behavior.
- Pass parsed model + system message sections to relay in the same shape relay already uses.

## Scope and Decisions

- Initial app scope: **Neox only**.
- `main.agent.md` model source: **YAML frontmatter**.
- Workspace initialization policy: **first launch only** (no overwrite when workspace exists).
- Parser behavior target: **match relay semantics** for frontmatter + section mapping.

## Target Runtime Layout

Workspace root:
- `<App Sandbox>/Library/Application Support/workspace`

Seed artifact in app bundle:
- `workspace.zip`

Expected seed contents (example):
- `workspace/.github/agents/main.agent.md`
- additional workspace files/folders needed by the app

## Shared Component Design (CopilotSDK)

### 1) WorkspaceBootstrapper

Purpose:
- Ensure app workspace exists at `Library/Application Support/workspace`.

Public API:
- `ensureWorkspaceReady(bundle: Bundle = .main) throws -> URL`

Behavior:
1. Compute `applicationSupportURL/workspace`.
2. If `workspace` exists: return URL immediately.
3. If missing:
   - Locate bundled `workspace.zip`.
   - Unzip into `applicationSupportURL`.
   - Validate resulting `workspace` exists.
4. Return workspace URL.

Notes:
- First-launch only behavior preserves user-edited files.
- No auto-update/overwrite in this iteration.

### 2) AgentProfileLoader

Purpose:
- Load `workspace/.github/agents/main.agent.md` and parse relay-compatible profile data.

Public API:
- `load(from workspaceURL: URL) throws -> AgentRuntimeProfile`

Profile model:
- `defaultModel: String?`
- `description: String?`
- `tools: [String]?`
- `preambleBody: String?`
- `sections: [String: SectionOverride]?`

Section override model:
- `action: "replace"`
- `content: String`

## Parser Semantics (Relay Parity)

Follow relay behavior from `copilot-relay/relay-server.js`:

1. Frontmatter
- Parse leading YAML block delimited by `---`.
- Parse simple `key: value` lines.
- Support at least:
  - `model`
  - `description`
  - `tools` array syntax like `[a, b, c]`

2. Body section parsing
- Parse body by `# Heading` boundaries.
- Normalize heading names to lowercase snake_case.
- Map aliases exactly to known section IDs.

Known section IDs:
- `identity`
- `tone`
- `tool_efficiency`
- `environment_context`
- `code_change_rules`
- `guidelines`
- `safety`
- `tool_instructions`
- `custom_instructions`
- `last_instructions`

Alias mapping examples:
- `core_behavior` -> `guidelines`
- `behavior` -> `guidelines`
- `tools` -> `tool_instructions`
- `environment` -> `environment_context`

3. Preamble fallback
- Content before first mapped section (and unmapped headers/content) becomes `preambleBody`.
- If no mapped sections exist, `preambleBody` acts as the fallback system message body.

4. Section payload shape
- Each mapped section becomes:
  - `{ action: "replace", content: "..." }`

## Neox Integration Design

## Startup / Initialization

1. On app startup (or coordinator initialization):
   - Call `WorkspaceBootstrapper.ensureWorkspaceReady(...)`.
   - Store resulting `workspaceURL`.
2. Create tool providers using same workspace URL:
   - `FileToolProvider(baseDirectory: workspaceURL)`
   - `FFmpegToolProvider(baseDirectory: workspaceURL)`

## Agent Session Construction

From `AgentRuntimeProfile`:
- Model selection:
  - Use `defaultModel` when available.
  - Fallback to current app default model otherwise.

System message to relay:
- If sections exist:
  - Send customize object with `sections`.
- Else if `preambleBody` exists:
  - Send body string fallback.
- Else:
  - Use current fallback behavior.

## Compatibility and Fallbacks

If any step fails (zip missing, unzip error, parse error):
- Neox continues with existing current behavior.
- Log structured diagnostics.
- Do not block app launch.

## Error Handling

Bootstrap errors:
- Missing `workspace.zip` in bundle.
- Unzip failure or corrupted zip.
- Permission/create directory failure.

Parser errors:
- Missing `main.agent.md`.
- Invalid/partial frontmatter.

Policy:
- Prefer non-fatal fallback over hard fail.
- Surface logs for debugging and telemetry.

## Testing Plan

### Unit tests (CopilotSDK)

Workspace bootstrap:
- Creates destination when missing.
- No-op when workspace exists.
- Throws expected errors for missing/corrupt zip.

Agent profile parser:
- Parses `model` from frontmatter.
- Parses `tools` array syntax.
- Maps headings to known section IDs.
- Produces `preambleBody` from unmapped content.
- Handles no-frontmatter/no-section fallback.

### Integration tests (Neox)

- Coordinator initializes workspace root in Application Support.
- File/media tools point to same workspace root.
- Session uses parsed model override when present.
- Relay payload uses sections object when sections are present.
- Fallback path works when profile file is missing.

## Rollout (Neox First)

1. Implement shared bootstrap + parser in CopilotSDK.
2. Wire Neox to use bootstrap URL for file/media tools.
3. Wire Neox session creation to use parsed model/sections.
4. Validate with local relay session and on-device launch.
5. After Neox stabilizes, apply same component to Intento.

## Open Items for Next Iteration

- Versioned workspace updates (replace on app version change).
- Merge strategy for seeded updates vs user-edited files.
- Optional support for richer YAML parsing beyond simple key/value.
- Optional export/import of workspace snapshots between app and relay.
