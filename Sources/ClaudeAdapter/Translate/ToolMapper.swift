import Foundation

struct ParsedToolCall {
    let name: String
    let arguments: [String: Any]
    let argumentsJSON: String
}

enum ToolMapper {
    static func buildCompactToolCatalog(tools: [ToolDefinition]) -> String {
        "Available tools:\n" + tools.map(\.compactSummary).joined(separator: "\n") + """


        Choose one exact tool name only when execution is required. Otherwise respond with final text.
        Do not generate arguments during tool selection.
        """
    }

    static func buildSelectedToolPrompt(_ tool: ToolDefinition) -> String {
        tool.selectedSchemaPrompt
    }

    static func buildToolPrompt(tools: [ToolDefinition]) -> String {
        var s = "Available tools:\n"
        for tool in tools {
            s += tool.summary + "\n"
        }
        s += """

        When you want to use a tool, set the toolCall field with the tool name and JSON arguments.
        When you want to respond with text, set the text field.
        Only call tools that are listed above. Do not invent tool names.
        """
        return s
    }

    static func parseArguments(_ json: String) -> (ParsedToolCall?, String) {
        guard let data = json.data(using: .utf8) else {
            return (nil, "arguments is not valid UTF-8")
        }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, "arguments is not a JSON object")
            }
            return (ParsedToolCall(name: "", arguments: obj, argumentsJSON: json), "")
        } catch {
            return (nil, "arguments JSON parse error: \(error)")
        }
    }

    static func validateGeneratedToolCall(
        name: String?,
        argumentsJSON: String,
        against tools: [ToolDefinition]
    ) -> (ParsedToolCall?, String) {
        guard let name, !name.isEmpty else {
            return (nil, "Generated tool call omitted the tool name.")
        }

        guard tools.contains(where: { $0.name == name }) else {
            return (nil, "Generated tool call requested unavailable tool '\(name)'.")
        }

        let (parsed, error) = parseArguments(argumentsJSON)
        guard let parsed else {
            return (nil, "Generated tool call for '\(name)' had invalid arguments: \(error).")
        }

        return (ParsedToolCall(name: name, arguments: parsed.arguments, argumentsJSON: parsed.argumentsJSON), "")
    }

    static func invalidToolCallText(_ reason: String) -> String {
        "I could not return a tool_use block because \(reason)"
    }

    static func makeToolUseID() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let rand = UInt64.random(in: 0...0xFFFFFFFF)
        return "toolu_afm_" + String(ms, radix: 32) + String(rand, radix: 32)
    }
}
