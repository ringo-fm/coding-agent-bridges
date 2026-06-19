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

@Generable(description: "Route the request. If the user asks to read, write, edit, search, run, or otherwise use an advertised tool, toolName is required and text must be nil. Otherwise return final text. Never claim a tool ran and never invent a tool name.")
struct ToolRoutingDecision {
    @Guide(description: "Final text only when no advertised tool is needed or requested. Never claim tool execution.")
    var text: String?
    @Guide(description: "Exact advertised tool name. Required when the user requests an action matching a tool.")
    var toolName: String?
}

@Generable(description: "Arguments for one already-selected tool.")
struct SelectedToolArguments {
    @Guide(description: "A valid JSON object matching the selected tool schema.")
    var arguments: String
}
