import Foundation
import FoundationModels

@Generable(description: "A tool call that the assistant wants to execute. Set text if responding with a normal message. Set toolCall if requesting a tool execution.")
struct AgentResponse {
    var text: String?
    var toolCall: ToolCallIntent?
}

@Generable(description: "A single tool call request with a tool name and JSON arguments.")
struct ToolCallIntent {
    @Guide(description: "The exact name of the tool to call (e.g. Bash, Read, Grep, Glob, Edit, Write, TodoWrite)")
    var name: String
    @Guide(description: "JSON-encoded arguments object for the tool. Must be valid JSON matching the tool's input schema.")
    var arguments: String
}

@Generable(description: "Choose whether to answer with text or call exactly one advertised tool. Never invent a tool name.")
struct ToolRoutingDecision {
    @Guide(description: "Final text response when no tool is required.")
    var text: String?
    @Guide(description: "Exact advertised tool name when a tool is required.")
    var toolName: String?
}

@Generable(description: "Arguments for one already-selected tool.")
struct SelectedToolArguments {
    @Guide(description: "A valid JSON object matching the selected tool schema.")
    var arguments: String
}
