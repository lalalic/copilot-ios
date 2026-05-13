// NeoxCore — shared infrastructure for Neox-family apps
//
// This package provides the generic app shell extracted from Neox:
// - ContextToolProvider: device context tool (time, battery, network, projects)
// - RegisteredTool: tool registry model
// - ChannelProvider: protocol for messaging channels (WeChat, Discord, etc.)
// - ProjectDiscovery: workspace project scanning and context loading
// - ProjectTypeHandler: protocol for custom project type behaviors
// - NeoxCoreSettings: shared UserDefaults keys and relay config helpers
// - ToolServerManager: MCP server lifecycle management
//
// Usage:
//   import NeoxCore
//
// Apps (Neox, Intento) import this + their domain-specific packages.

@_exported import CopilotSDK
@_exported import CopilotChat
