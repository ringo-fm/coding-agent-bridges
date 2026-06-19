import Testing
import Foundation
@testable import ClaudeAdapter

@Suite struct ToolDefinitionTests {
    @Test func decodesToolWithSchema() throws {
        let json = """
        {"name":"Bash","description":"Execute a bash command","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"The command to run"}},"required":["command"]}}
        """.data(using: .utf8)!
        let tool = try JSONDecoder().decode(ToolDefinition.self, from: json)
        #expect(tool.name == "Bash")
        #expect(tool.description == "Execute a bash command")
        #expect(tool.inputSchema?.type == "object")
        #expect(tool.inputSchema?.required == ["command"])
        #expect(tool.inputSchema?.properties?["command"]?.type == "string")
    }

    @Test func summaryIncludesNameAndProperties() {
        let tool = ToolDefinition(name: "Read", description: "Read a file", inputSchema: ToolInputSchema(
            type: "object",
            properties: ["path": ToolProperty(type: "string", description: "File path")],
            required: ["path"]
        ))
        let s = tool.summary
        #expect(s.contains("- Read"))
        #expect(s.contains("path: string (required)"))
    }
}

@Suite struct ToolMapperTests {
    @Test func buildToolPromptListsTools() {
        let tools = [
            ToolDefinition(name: "Bash", description: "Run commands", inputSchema: nil),
            ToolDefinition(name: "Read", description: "Read files", inputSchema: nil),
        ]
        let prompt = ToolMapper.buildToolPrompt(tools: tools)
        #expect(prompt.contains("- Bash"))
        #expect(prompt.contains("- Read"))
        #expect(prompt.contains("Available tools:"))
        #expect(prompt.contains("toolCall field"))
    }

    @Test func parseValidArguments() {
        let (parsed, err) = ToolMapper.parseArguments("{\"command\":\"ls -la\"}")
        #expect(err.isEmpty)
        #expect(parsed != nil)
        #expect(parsed?.arguments["command"] as? String == "ls -la")
    }

    @Test func parseInvalidArguments() {
        let (parsed, err) = ToolMapper.parseArguments("not json")
        #expect(!err.isEmpty)
        #expect(parsed == nil)
    }

    @Test func makeToolUseIDHasPrefix() {
        let id = ToolMapper.makeToolUseID()
        #expect(id.hasPrefix("toolu_afm_"))
    }

    @Test func validatesAdvertisedToolCallWithJSONObjectArguments() {
        let tools = [ToolDefinition(name: "Bash", description: "Run commands", inputSchema: nil)]
        let (parsed, error) = ToolMapper.validateGeneratedToolCall(
            name: "Bash",
            argumentsJSON: "{\"command\":\"pwd\"}",
            against: tools
        )

        #expect(error.isEmpty)
        #expect(parsed?.name == "Bash")
        #expect(parsed?.arguments["command"] as? String == "pwd")
    }

    @Test func rejectsUnavailableGeneratedToolName() {
        let tools = [ToolDefinition(name: "Read", description: "Read files", inputSchema: nil)]
        let (parsed, error) = ToolMapper.validateGeneratedToolCall(
            name: "Bash",
            argumentsJSON: "{\"command\":\"pwd\"}",
            against: tools
        )

        #expect(parsed == nil)
        #expect(error.contains("unavailable tool 'Bash'"))
    }

    @Test func rejectsMalformedGeneratedToolArguments() {
        let tools = [ToolDefinition(name: "Bash", description: "Run commands", inputSchema: nil)]
        let (parsed, error) = ToolMapper.validateGeneratedToolCall(
            name: "Bash",
            argumentsJSON: "not json",
            against: tools
        )

        #expect(parsed == nil)
        #expect(error.contains("invalid arguments"))
    }
}

