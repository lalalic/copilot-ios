# CopilotSDK Swift - Future Tasks

## Known Limitations

### Hooks not invoked by CLI v1.0.11
- **Status**: Typed hook API implemented and compiles, but CLI v1.0.11 never actually sends `hooks.invoke` RPC requests or `hooks.*` events
- **Impact**: `onPreToolUse`, `onPostToolUse`, `onUserPromptSubmitted`, `onSessionStart`, `onSessionEnd`, `onErrorOccurred` callbacks are never fired
- **Test**: `testHooks_PreToolUse` passes (tool works, session works) but `hookCalled` is always `false`
- **Action**: Re-test with newer CLI versions. The hooks.invoke RPC handler and event-based dispatch are fully implemented and ready.
- **Both v1 (event) and v2 (RPC) protocols** are handled:
  - v1: `hooks.pre_tool_use` etc. events in `startEventDispatch()` → `handleHookEvent()`
  - v2: `hooks.invoke` RPC request in `registerRequestHandler()` during session init

### getMessages returns empty
- `session.getMessages()` RPC call succeeds but returns 0 messages
- May require different RPC method or newer CLI version

### User input (ask_questions tool) not reliably triggered
- Model doesn't always use the `ask_questions` tool when asked
- `onUserInputRequest` callback is implemented but depends on model behavior
- Both v1 (event-based) and v2 (RPC-based) handlers are wired up

## Feature Gaps vs Official SDK

### Telemetry
- `TelemetryConfig` with OTLP endpoint, file output, content capture
- `onGetTraceContext` for distributed trace linking
- Not implemented yet

### Model List
- `listModels()` to discover available models and their capabilities
- Not implemented yet
