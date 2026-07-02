import Foundation
import AgentBridgeCore

struct NormalizedBlock: Sendable {
    enum Kind: Sendable {
        case text(String)
        case toolResult(ToolResultSegment)
        case toolUse(name: String?, id: String?, input: String?)
        case thinking(String)
        case unsupported(type: String)
    }
    let kind: Kind
}

struct ToolResultSegment: Sendable {
    let toolUseId: String
    let content: String
    let isError: Bool
}

struct NormalizedTurn: Sendable {
    let role: String
    let blocks: [NormalizedBlock]
}

struct NormalizedRequest: Sendable {
    let model: String
    let systemText: String?
    let turns: [NormalizedTurn]
    let stream: Bool
    let temperature: Double?
    let maxTokens: Int?
    let tools: [ToolDefinition]?
    let toolChoice: AgentToolChoice
    let toolChoicePresent: Bool
    let thinkingPresent: Bool

    var toolsPresent: Bool { tools != nil }
    var hasTools: Bool { !(tools?.isEmpty ?? true) }

    init(
        model: String,
        systemText: String?,
        turns: [NormalizedTurn],
        stream: Bool,
        temperature: Double?,
        maxTokens: Int?,
        tools: [ToolDefinition]?,
        toolChoice: AgentToolChoice = .auto,
        toolChoicePresent: Bool,
        thinkingPresent: Bool
    ) {
        self.model = model
        self.systemText = systemText
        self.turns = turns
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.tools = tools
        self.toolChoice = toolChoice
        self.toolChoicePresent = toolChoicePresent
        self.thinkingPresent = thinkingPresent
    }
}

enum MessageNormalizer {
    static func normalize(_ req: MessagesRequest, diagnostics: Diagnostics) -> NormalizedRequest {
        if req.thinkingPresent { diagnostics.ignoredField("thinking") }

        let turns = req.messages.map { msg -> NormalizedTurn in
            NormalizedTurn(role: msg.role, blocks: msg.content.blockList.map { blockKind($0, for: msg.role, diagnostics: diagnostics) })
        }

        return NormalizedRequest(
            model: req.model,
            systemText: req.system?.flattenedText,
            turns: turns,
            stream: req.stream ?? false,
            temperature: req.temperature,
            maxTokens: req.maxTokens,
            tools: req.tools,
            toolChoice: req.toolChoice?.agentChoice ?? .auto,
            toolChoicePresent: req.toolChoicePresent,
            thinkingPresent: req.thinkingPresent
        )
    }

    static func normalizeForCount(_ req: CountTokensRequest, diagnostics: Diagnostics) -> NormalizedRequest? {
        if req.toolsPresent { diagnostics.ignoredField("tools", detail: "(count_tokens: tools ignored)") }
        if req.thinkingPresent { diagnostics.ignoredField("thinking", detail: "(count_tokens: thinking ignored)") }
        guard let messages = req.messages, !messages.isEmpty else { return nil }
        let turns = messages.map { msg -> NormalizedTurn in
            NormalizedTurn(role: msg.role, blocks: msg.content.blockList.map { blockKind($0, for: msg.role, diagnostics: diagnostics) })
        }
        return NormalizedRequest(
            model: req.model ?? ModelRegistry.primaryModel,
            systemText: req.system?.flattenedText,
            turns: turns,
            stream: false,
            temperature: nil,
            maxTokens: nil,
            tools: nil,
            toolChoice: .auto,
            toolChoicePresent: false,
            thinkingPresent: req.thinkingPresent
        )
    }

    private static func blockKind(_ block: RequestContentBlock, for role: String, diagnostics: Diagnostics) -> NormalizedBlock {
        switch block {
        case .text(let t):
            return NormalizedBlock(kind: .text(t))
        case .toolResult(let r):
            return NormalizedBlock(kind: .toolResult(ToolResultSegment(
                toolUseId: r.toolUseId,
                content: r.flattenedContent,
                isError: r.isError ?? false)))
        case .toolUse(let u):
            return NormalizedBlock(kind: .toolUse(name: u.name, id: u.id, input: u.inputJSON))
        case .thinking(let t):
            diagnostics.ignoredField("thinking", detail: "(content block)")
            return NormalizedBlock(kind: .thinking(t))
        case .unknown(let type):
            diagnostics.unsupportedBlock(type, in: role)
            return NormalizedBlock(kind: .unsupported(type: type))
        }
    }
}
