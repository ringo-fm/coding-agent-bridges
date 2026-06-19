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

