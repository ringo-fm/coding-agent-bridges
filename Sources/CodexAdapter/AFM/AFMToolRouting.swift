import FoundationModels

@Generable(description: "Choose whether to answer directly or call exactly one advertised tool. Never invent a tool name.")
struct CodexToolRoutingDecision {
    @Guide(description: "Final response when no advertised tool is needed. Set to nil when selecting a tool.")
    var text: String?

    @Guide(description: "Exact advertised tool name when repository inspection, command execution, editing, or another tool action is required.")
    var toolName: String?
}

@Generable(description: "Generate the JSON arguments object for the selected tool.")
struct CodexSelectedToolArguments {
    @Guide(description: "A valid JSON object matching the selected tool schema.")
    var arguments: String
}
