import AgentBridgeCore
import Foundation
import FoundationModels
import Synchronization

@Generable(description: "Determine whether a final text response alone can fully complete the current request. Evaluate completion, not whether you can describe a plan.")
struct AFMExternalActionRequirement {
    @Guide(description: "True only when all required facts are already present and no file read, command, user interaction, or external change is needed. Return false if any external step remains; describing that step is not completion.")
    var canCompleteWithTextOnly: Bool
}

enum AFMToolExecution {
    static func generate(
        model: SystemLanguageModel,
        request: AgentGenerationRequest,
        instructions: String,
        prompt: String,
        options: GenerationOptions
    ) async throws -> AgentGenerationResult {
        let tools = eligibleTools(request.tools, choice: request.toolChoice)
        guard !tools.isEmpty, request.toolChoice != .none else {
            let session = makeSession(model: model, instructions: instructions)
            let text = try await session.respond(to: prompt, options: options).content
            return AgentGenerationResult(text: text)
        }

        let catalog = tools.map {
            "- \($0.name): \(String($0.description.prefix(240)))"
        }.joined(separator: "\n")
        let routingInstructions = """
        Available external tools:
        \(catalog)

        Decide only whether the next step is an external tool call or a final response.
        Select the exact tool name whenever completing the request requires reading external state, running a command, or changing anything outside this model session.
        A final response is valid only when the supplied context already contains everything needed and no external action remains.
        Tool execution is performed by the coding agent, not by this model session.
        """
        let decisionPrompt = [instructions, request.decisionContext ?? prompt]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        if request.executionStrategy != .staged,
           let native = try await nativeGenerateIfItFits(
                model: model,
                tools: tools,
                prompt: decisionPrompt,
                instructions: instructions,
                options: options
           ), !native.toolCalls.isEmpty {
            return native
        }

        let selectedName: String?
        switch request.toolChoice {
        case .tool(let name):
            selectedName = name
        case .required where tools.count == 1:
            selectedName = tools[0].name
        default:
            let session = makeSession(model: model, instructions: routingInstructions)
            let requirement = try await session.respond(
                to: decisionPrompt,
                generating: AFMExternalActionRequirement.self,
                options: options
            ).content
            if !requirement.canCompleteWithTextOnly || request.toolChoice == .required {
                let candidates = try await selectToolCandidates(
                    model: model,
                    tools: tools,
                    prompt: decisionPrompt,
                    instructions: routingInstructions,
                    options: options
                )
                let candidateTools = candidates.compactMap { name in tools.first { $0.name == name } }
                if candidateTools.count > 1,
                   let native = try await nativeGenerateIfItFits(
                        model: model,
                        tools: candidateTools,
                        prompt: decisionPrompt,
                        instructions: instructions,
                        options: options
                   ), !native.toolCalls.isEmpty {
                    return native
                }
                selectedName = candidates.first
            } else {
                selectedName = nil
            }
        }

        guard let selectedName,
              let selected = tools.first(where: { $0.name == selectedName }) else {
            if request.toolChoice == .required {
                throw AgentBackendError.generationFailed("the model did not select a required tool")
            }
            let session = makeSession(model: model, instructions: instructions)
            let text = try await session.respond(to: prompt, options: options).content
            return AgentGenerationResult(text: text)
        }

        let schema = try schema(for: selected)
        let argumentInstructions = """
        Generate arguments for the selected external tool.
        Tool: \(selected.name)
        Description: \(selected.description)
        The result must satisfy the supplied schema. Do not execute the tool.
        """
        let session = makeSession(model: model, instructions: argumentInstructions)
        let content = try await session.respond(
            to: decisionPrompt,
            schema: schema,
            includeSchemaInPrompt: true,
            options: options
        ).content
        let arguments = content.jsonString
        try validateJSONObject(arguments)
        return AgentGenerationResult(
            text: "",
            toolCalls: [AgentToolCall(
                id: "call_afm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                name: selected.name,
                argumentsJSON: arguments
            )]
        )
    }

    private static func eligibleTools(
        _ tools: [AgentToolDefinition],
        choice: AgentToolChoice
    ) -> [AgentToolDefinition] {
        if case .tool(let name) = choice { return tools.filter { $0.name == name } }
        return tools
    }

    private static func nativeGenerateIfItFits(
        model: SystemLanguageModel,
        tools: [AgentToolDefinition],
        prompt: String,
        instructions: String,
        options: GenerationOptions
    ) async throws -> AgentGenerationResult? {
        let capturingTools = try tools.map(AFMCapturedExternalTool.init)
        let afmTools = capturingTools.map { $0 as any Tool }
        let nativeInstructions = [instructions, """
        Use an available tool whenever completing the request requires reading external state, running a command, or making a change. Tool outputs indicating delegated execution mean the coding agent will execute the call and return the real result in the next turn. Do not replace a required tool call with instructions for the user.
        """].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if #available(macOS 26.4, *) {
            let toolTokens = try await model.tokenCount(for: afmTools)
            let promptTokens = try await model.tokenCount(for: prompt)
            let instructionTokens = try await model.tokenCount(for: nativeInstructions)
            guard toolTokens + promptTokens + instructionTokens < model.contextSize * 3 / 4 else { return nil }
        } else {
            return nil
        }

        let session = LanguageModelSession(model: model, tools: afmTools, instructions: nativeInstructions)
        _ = try await session.respond(to: prompt, options: options)
        let calls = capturingTools.flatMap { $0.drain() }
        guard !calls.isEmpty else { return nil }
        return AgentGenerationResult(text: "", toolCalls: calls)
    }

    private static func selectToolCandidates(
        model: SystemLanguageModel,
        tools: [AgentToolDefinition],
        prompt: String,
        instructions: String,
        options: GenerationOptions
    ) async throws -> [String] {
        if tools.count == 1 { return [tools[0].name] }
        let toolName = DynamicGenerationSchema(
            name: "ExternalToolName",
            description: "An exact advertised tool name relevant to the next action.",
            anyOf: tools.map(\.name)
        )
        let root = DynamicGenerationSchema(
            arrayOf: toolName,
            minimumElements: 1,
            maximumElements: min(3, tools.count)
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = makeSession(model: model, instructions: instructions)
        return try await session.respond(
            to: prompt,
            schema: schema,
            includeSchemaInPrompt: true,
            options: options
        ).content.value([String].self)
    }

    fileprivate static func schema(for tool: AgentToolDefinition) throws -> GenerationSchema {
        let object = try JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))
        guard let dictionary = object as? [String: Any] else {
            throw AgentBackendError.generationFailed("tool schema for '\(tool.name)' is not an object")
        }
        let root = dynamicSchema(
            dictionary,
            name: sanitizedSchemaName(tool.name),
            description: tool.description
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func dynamicSchema(
        _ value: [String: Any],
        name: String,
        description: String? = nil
    ) -> DynamicGenerationSchema {
        if let choices = value["enum"] as? [String], !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }
        switch (value["type"] as? String) ?? "object" {
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            let item = (value["items"] as? [String: Any]) ?? ["type": "string"]
            return DynamicGenerationSchema(arrayOf: dynamicSchema(item, name: name + "Item"))
        case "object":
            let required = Set(value["required"] as? [String] ?? [])
            let properties = (value["properties"] as? [String: Any] ?? [:]).compactMap { key, raw -> DynamicGenerationSchema.Property? in
                guard let property = raw as? [String: Any] else { return nil }
                return DynamicGenerationSchema.Property(
                    name: key,
                    description: property["description"] as? String,
                    schema: dynamicSchema(property, name: sanitizedSchemaName(name + "_" + key)),
                    isOptional: !required.contains(key)
                )
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    private static func sanitizedSchemaName(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars)
        return result.first?.isNumber == true ? "Tool_" + result : result
    }

    private static func validateJSONObject(_ value: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data(value.utf8))
        guard object is [String: Any] else {
            throw AgentBackendError.generationFailed("generated tool arguments are not a JSON object")
        }
    }

    private static func makeSession(model: SystemLanguageModel, instructions: String) -> LanguageModelSession {
        instructions.isEmpty ? LanguageModelSession(model: model) : LanguageModelSession(model: model, instructions: instructions)
    }
}

private final class AFMCapturedExternalTool: Tool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let includesSchemaInInstructions = true
    private let calls = Mutex<[AgentToolCall]>([])

    init(definition: AgentToolDefinition) throws {
        name = definition.name
        description = definition.description
        parameters = try AFMToolExecution.schema(for: definition)
    }

    func call(arguments: GeneratedContent) async throws -> String {
        calls.withLock {
            $0.append(AgentToolCall(
                id: "call_afm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                name: name,
                argumentsJSON: arguments.jsonString
            ))
        }
        return "The external call was captured for execution by the coding agent. Stop and wait for its real result."
    }

    func drain() -> [AgentToolCall] {
        calls.withLock {
            let result = $0
            $0 = []
            return result
        }
    }
}
