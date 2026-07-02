import Testing
import Foundation
@testable import CodexAdapter

@Suite("Tool mapping")
struct ToolMappingTests {

    @Test("ToolMapper maps a function tool with string parameter")
    func mapFunctionTool() throws {
        let tool = ResponsesTool(
            type: "function",
            name: "read_file",
            description: "Read a file",
            parameters: ResponsesToolParameters(
                type: "object",
                properties: [
                    "path": ResponsesToolParameterProperty(type: "string", description: "File path")
                ],
                required: ["path"]
            )
        )
        let registry = try #require(ToolMapper.map([tool]))
        #expect(registry.afmTools.count == 1)
        #expect(registry.afmTools.first?.name == "read_file")
        #expect(registry.afmTools.first?.description == "Read a file")
    }

    @Test("ToolMapper maps multiple tools")
    func mapMultipleTools() throws {
        let tools = [
            ResponsesTool(type: "function", name: "read_file", description: "Read"),
            ResponsesTool(type: "function", name: "shell", description: "Run command"),
            ResponsesTool(type: "function", name: "apply_patch", description: "Apply patch")
        ]
        let registry = try #require(ToolMapper.map(tools))
        #expect(registry.afmTools.count == 3)
        let names = registry.afmTools.map(\.name)
        #expect(names.contains("read_file"))
        #expect(names.contains("shell"))
        #expect(names.contains("apply_patch"))
    }

    @Test("ToolMapper can restrict the AFM catalog to core coding tools")
    func mapCoreToolAllowlist() throws {
        let registry = try #require(ToolMapper.map([
            ResponsesTool(type: "function", name: "exec_command", description: "Run command"),
            ResponsesTool(type: "function", name: "view_image", description: "View image"),
            ResponsesTool(type: "function", name: "request_user_input", description: "Ask")
        ], allowedNames: codexAFMCoreToolNames))
        #expect(registry.names == ["exec_command", "request_user_input"])
    }

    @Test("ToolMapper returns nil for empty tools")
    func mapEmptyTools() {
        #expect(ToolMapper.map([]) == nil)
    }

    @Test("ToolMapper skips non-function tool types")
    func mapNonFunctionTool() throws {
        let tools = [
            ResponsesTool(type: "web_search", name: "search"),
            ResponsesTool(type: "function", name: "read_file", description: "Read")
        ]
        let registry = try #require(ToolMapper.map(tools))
        // Only the function tool is mapped.
        #expect(registry.afmTools.count == 1)
        #expect(registry.afmTools.first?.name == "read_file")
    }

    @Test("ToolMapper handles tool without parameters")
    func mapToolWithoutParameters() throws {
        let tool = ResponsesTool(type: "function", name: "noop", description: "No-op tool")
        let registry = try #require(ToolMapper.map([tool]))
        #expect(registry.afmTools.count == 1)
        #expect(registry.afmTools.first?.name == "noop")
    }

    @Test("ToolMapper handles integer and boolean parameter types")
    func mapTypedParameters() throws {
        let tool = ResponsesTool(
            type: "function",
            name: "config",
            description: "Set config",
            parameters: ResponsesToolParameters(
                type: "object",
                properties: [
                    "port": ResponsesToolParameterProperty(type: "integer", description: "Port number"),
                    "enabled": ResponsesToolParameterProperty(type: "boolean", description: "Enabled flag"),
                    "ratio": ResponsesToolParameterProperty(type: "number", description: "Ratio")
                ],
                required: ["port"]
            )
        )
        let registry = try #require(ToolMapper.map([tool]))
        #expect(registry.afmTools.count == 1)
    }

    @Test("BridgedToolRegistry starts with no captured calls")
    func registryNoCapturedCalls() throws {
        let tool = ResponsesTool(type: "function", name: "test", description: "Test")
        let registry = try #require(ToolMapper.map([tool]))
        #expect(registry.drainAllCapturedCalls().isEmpty)
    }

    @Test("BridgedToolRegistry exposes a compact catalog and one selected schema")
    func registrySelection() throws {
        let registry = try #require(ToolMapper.map([
            ResponsesTool(type: "function", name: "read_file", description: "Read a file"),
            ResponsesTool(type: "function", name: "shell", description: "Run a command")
        ]))
        #expect(registry.compactCatalog.contains("read_file: Read a file"))
        #expect(registry.compactCatalog.contains("shell: Run a command"))
        let selected = try #require(registry.selecting(name: "shell"))
        #expect(selected.names == ["shell"])
        #expect(selected.afmTools.count == 1)
        #expect(registry.selecting(name: "missing") == nil)
    }

    @Test("exec_command arguments cannot request escalation")
    func sanitizeExecCommandArguments() throws {
        let sanitized = AFMRuntime.sanitizeToolArguments(
            #"{"cmd":"rg --files","sandbox_permissions":"require_escalated","justification":"needed","prefix_rule":["rg"]}"#,
            toolName: "exec_command"
        )
        let data = try #require(sanitized.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["cmd"] as? String == "rg --files")
        #expect(object["sandbox_permissions"] as? String == "use_default")
        #expect(object["justification"] == nil)
        #expect(object["prefix_rule"] == nil)
    }

    @Test("ResponsesOutputItem.functionCall creates correct shape")
    func functionCallOutputItem() {
        let item = ResponsesOutputItem.functionCall(
            id: "fc_1", callID: "call_1", name: "read_file", arguments: "{\"path\":\"README.md\"}"
        )
        #expect(item.type == "function_call")
        #expect(item.status == .completed)
        #expect(item.call_id == "call_1")
        #expect(item.name == "read_file")
        #expect(item.arguments == "{\"path\":\"README.md\"}")
        #expect(item.role == nil)
        #expect(item.content == nil)
    }

    @Test("ResponsesOutputItem encodes function_call without role/content")
    func functionCallEncoding() throws {
        let item = ResponsesOutputItem.functionCall(
            id: "fc_1", callID: "call_1", name: "shell", arguments: "{\"command\":\"ls\"}"
        )
        let data = try JSONEncoder().encode(item)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"type\":\"function_call\""))
        #expect(json.contains("\"name\":\"shell\""))
        #expect(json.contains("\"call_id\":\"call_1\""))
        // role and content should be absent
        #expect(!json.contains("\"role\""))
        #expect(!json.contains("\"content\""))
    }

    @Test("InputNormalizer captures function_call items when enabled")
    func normalizeFunctionCallInput() {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .items([
                .user(text: "Read README.md"),
                ResponsesInputItem(type: "function_call", call_id: "call_1", name: "read_file", arguments: "{\"path\":\"README.md\"}")
            ]),
            tools: [ResponsesTool(type: "function", name: "read_file", description: "Read")]
        )
        let normalized = InputNormalizer.normalize(request, flags: .codexTools)
        #expect(normalized.toolCalls.count == 1)
        #expect(normalized.toolCalls.first?.name == "read_file")
        #expect(normalized.toolCalls.first?.callID == "call_1")
        #expect(normalized.toolCalls.first?.arguments == "{\"path\":\"README.md\"}")
    }

    @Test("InputNormalizer captures function_call_output items when enabled")
    func normalizeFunctionCallOutput() {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .items([
                .user(text: "Read README.md"),
                ResponsesInputItem(type: "function_call_output", call_id: "call_1", arguments: "# README\nHello world")
            ]),
            tools: [ResponsesTool(type: "function", name: "read_file", description: "Read")]
        )
        let normalized = InputNormalizer.normalize(request, flags: .codexTools)
        #expect(normalized.toolOutputs.count == 1)
        #expect(normalized.toolOutputs.first?.callID == "call_1")
        #expect(normalized.toolOutputs.first?.output == "# README\nHello world")
    }

    @Test("next tool turn preserves instructions and tool output")
    func nextToolTurnPreservesInstructionsAndToolOutput() {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            instructions: "Only create output/report.md.",
            input: .items([
                .user(text: "Complete TASK.md"),
                ResponsesInputItem(
                    type: "function_call_output",
                    call_id: "call_1",
                    arguments: "active IDs are 3 and 11"
                )
            ]),
            tools: [ResponsesTool(type: "function", name: "exec_command", description: "Run a command")]
        )
        let normalized = InputNormalizer.normalize(request, flags: .codexTools)
        let prompt = PromptBuilder.build(from: normalized)
        #expect(normalized.instructions == "Only create output/report.md.")
        #expect(prompt.contains("System instructions:\nOnly create output/report.md."))
        #expect(prompt.contains("[tool_output call_1] active IDs are 3 and 11"))
    }

    @Test("InputNormalizer preserves message, tool call, and output order")
    func normalizedEventsPreserveWireOrder() {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .items([
                .user(text: "Inspect the package"),
                ResponsesInputItem(
                    type: "function_call", id: "fc_1", call_id: "call_1",
                    name: "exec_command", arguments: #"{"cmd":"pwd"}"#
                ),
                ResponsesInputItem(
                    type: "function_call_output", call_id: "call_1",
                    output: "/tmp/project\n"
                )
            ])
        )
        let normalized = InputNormalizer.normalize(request, flags: .codexTools)
        #expect(normalized.events.count == 3)
        guard case .message = normalized.events[0] else { Issue.record("first event must be message"); return }
        guard case .toolCall = normalized.events[1] else { Issue.record("second event must be tool call"); return }
        guard case .toolOutput = normalized.events[2] else { Issue.record("third event must be tool output"); return }
    }

    @Test("InputNormalizer ignores function_call items when function-call disabled")
    func normalizeFunctionCallDisabled() {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .items([
                .user(text: "Read README.md"),
                ResponsesInputItem(type: "function_call", call_id: "call_1", name: "read_file", arguments: "{}")
            ])
        )
        let normalized = InputNormalizer.normalize(request, flags: .codexMinimal)
        #expect(normalized.toolCalls.isEmpty)
        #expect(normalized.diagnostics.ignoredFields.contains("function_call"))
    }

    @Test("PromptBuilder includes tool call history in conversation")
    func promptBuilderToolHistory() {
        let normalized = NormalizedInput(
            instructions: nil,
            messages: [NormalizedMessage(role: .user, text: "Read README.md")],
            toolCalls: [NormalizedToolCall(callID: "call_1", name: "read_file", arguments: "{\"path\":\"README.md\"}")],
            toolOutputs: [NormalizedToolOutput(callID: "call_1", output: "# README\nHello")],
            diagnostics: Diagnostics()
        )
        let prompt = PromptBuilder.build(from: normalized)
        #expect(prompt.contains("[assistant tool_call] read_file"))
        #expect(prompt.contains("[tool_output call_1] # README"))
    }

    @Test("FeatureFlags.loadOverrides reads explicit environment variables")
    func featureFlagsEnvOverride() {
        let flags = FeatureFlags.loadOverrides(
            from: [
                "AFM_BRIDGE_FEATURE_FUNCTION_CALL": "true",
                "AFM_BRIDGE_FEATURE_SHELL_CALL": "1",
                "AFM_BRIDGE_FEATURE_APPLY_PATCH": "false"
            ],
            base: .codexMinimal
        )
        #expect(flags.functionCall)
        #expect(flags.shellCall)
        #expect(!flags.applyPatchCall)
    }

    @Test("CompatibilityProfile.codexTools enables function call")
    func codexToolsProfile() {
        let profile = CompatibilityProfile.codexTools
        #expect(profile.flags.functionCall)
        #expect(profile.flags.shellCall)
        #expect(profile.flags.applyPatchCall)
    }

    @Test("CompatibilityProfile.load defaults to codex-minimal")
    func profileLoadDefault() {
        let profile = CompatibilityProfile.load(from: [:])
        #expect(profile.name == "codex-minimal")
        #expect(!profile.flags.functionCall)
        #expect(!profile.flags.shellCall)
        #expect(!profile.flags.applyPatchCall)
    }

    @Test("CompatibilityProfile.load selects codex-tools")
    func profileLoadCodexTools() {
        let profile = CompatibilityProfile.load(from: ["AFM_BRIDGE_PROFILE": "codex-tools"])
        #expect(profile.name == "codex-tools")
        #expect(profile.flags.functionCall)
        #expect(profile.flags.shellCall)
        #expect(profile.flags.applyPatchCall)
    }

    @Test("CompatibilityProfile.load applies feature overrides")
    func profileLoadFeatureOverrides() {
        let profile = CompatibilityProfile.load(
            from: [
                "AFM_BRIDGE_PROFILE": "codex-tools",
                "AFM_BRIDGE_FEATURE_FUNCTION_CALL": "0",
                "AFM_BRIDGE_FEATURE_APPLY_PATCH": "false"
            ]
        )
        #expect(profile.name == "codex-tools")
        #expect(!profile.flags.functionCall)
        #expect(profile.flags.shellCall)
        #expect(!profile.flags.applyPatchCall)
    }

    @Test("CompatibilityProfile.load falls back to codex-minimal for unknown names")
    func profileLoadUnknownFallsBack() {
        let profile = CompatibilityProfile.load(from: ["AFM_BRIDGE_PROFILE": "unknown"])
        #expect(profile.name == "codex-minimal")
        #expect(!profile.flags.functionCall)
    }

    @Test("OutputMapper includes function_call items in response")
    func outputMapperWithToolCalls() {
        var diags = Diagnostics()
        let result = AFMGenerateResult(
            text: "Let me read that file.",
            toolCalls: [CapturedToolCall(name: "read_file", argumentsJSON: "{\"path\":\"README.md\"}")]
        )
        let response = OutputMapper.toResponsesObject(
            responseID: "resp_1",
            model: "apple-foundation-local",
            result: result,
            diagnostics: &diags
        )
        #expect(response.output.count == 2)
        #expect(response.output[0].type == "message")
        #expect(response.output[1].type == "function_call")
        #expect(response.output[1].name == "read_file")
        #expect(response.output[1].arguments == "{\"path\":\"README.md\"}")
    }
}
