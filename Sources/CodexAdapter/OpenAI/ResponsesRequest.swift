import Foundation

// MARK: - Top-level request

/// POST /v1/responses request body. Only the MVP subset is modeled here.
/// Unknown fields are tolerated and recorded via `Diagnostics`.
public struct ResponsesCreateRequest: Codable, Sendable {
    public var model: String
    public var instructions: String?
    public var input: ResponsesInput
    public var stream: Bool?
    public var temperature: Double?
    public var max_output_tokens: Int?
    public var top_p: Double?
    public var tools: [ResponsesTool]?
    public var reasoning: ResponsesReasoning?
    public var previous_response_id: String?
    public var store: Bool?
    public var metadata: [String: String]?

    public init(
        model: String,
        instructions: String? = nil,
        input: ResponsesInput,
        stream: Bool? = nil,
        temperature: Double? = nil,
        max_output_tokens: Int? = nil,
        top_p: Double? = nil,
        tools: [ResponsesTool]? = nil,
        reasoning: ResponsesReasoning? = nil,
        previous_response_id: String? = nil,
        store: Bool? = nil,
        metadata: [String: String]? = nil
    ) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.stream = stream
        self.temperature = temperature
        self.max_output_tokens = max_output_tokens
        self.top_p = top_p
        self.tools = tools
        self.reasoning = reasoning
        self.previous_response_id = previous_response_id
        self.store = store
        self.metadata = metadata
    }
}

// MARK: - Input

/// `input` can be either a plain string or an array of input items.
public enum ResponsesInput: Codable, Sendable, Equatable {
    case text(String)
    case items([ResponsesInputItem])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .text(s)
            return
        }
        let items = try c.decode([ResponsesInputItem].self)
        self = .items(items)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s):
            try c.encode(s)
        case .items(let items):
            try c.encode(items)
        }
    }

    /// Flatten to a list of items. A bare string becomes a single user message
    /// containing one `input_text` part.
    public var asItems: [ResponsesInputItem] {
        switch self {
        case .text(let s):
            return [.user(text: s)]
        case .items(let items):
            return items
        }
    }
}

/// One entry in the `input` array. Roles map to the Responses API message roles.
/// Also covers `function_call` and `function_call_output` item types.
public struct ResponsesInputItem: Codable, Sendable, Equatable {
    public var type: String?
    public var role: String?
    public var content: [ResponsesInputContent]?
    public var status: String?
    public var id: String?
    public var call_id: String?
    public var name: String?
    public var arguments: String?
    public var output: String?

    public init(
        type: String? = nil,
        role: String? = nil,
        content: [ResponsesInputContent]? = nil,
        status: String? = nil,
        id: String? = nil,
        call_id: String? = nil,
        name: String? = nil,
        arguments: String? = nil,
        output: String? = nil
    ) {
        self.type = type
        self.role = role
        self.content = content
        self.status = status
        self.id = id
        self.call_id = call_id
        self.name = name
        self.arguments = arguments
        self.output = output
    }

    /// Convenience constructor for a plain user text message.
    public static func user(text: String) -> ResponsesInputItem {
        ResponsesInputItem(
            type: "message",
            role: "user",
            content: [.text(text)]
        )
    }
}

/// A single content part inside an input item.
public struct ResponsesInputContent: Codable, Sendable, Equatable {
    public var type: String
    public var text: String?
    public var detail: String?

    public init(type: String, text: String? = nil, detail: String? = nil) {
        self.type = type
        self.text = text
        self.detail = detail
    }

    public static func text(_ s: String) -> ResponsesInputContent {
        ResponsesInputContent(type: "input_text", text: s)
    }

    public static func image(_ imageURL: String) -> ResponsesInputContent {
        ResponsesInputContent(type: "input_image", text: imageURL)
    }
}

// MARK: - Tools (ignored in v0, but parsed so we can record diagnostics)

public struct ResponsesTool: Codable, Sendable, Equatable {
    public var type: String
    public var name: String?
    public var description: String?
    public var parameters: ResponsesToolParameters?

    public init(type: String, name: String? = nil, description: String? = nil, parameters: ResponsesToolParameters? = nil) {
        self.type = type
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ResponsesToolParameters: Codable, Sendable, Equatable {
    public var type: String?
    public var properties: [String: ResponsesToolParameterProperty]?
    public var required: [String]?

    public init(type: String? = nil, properties: [String: ResponsesToolParameterProperty]? = nil, required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct ResponsesToolParameterProperty: Codable, Sendable, Equatable {
    public var type: String?
    public var description: String?

    public init(type: String? = nil, description: String? = nil) {
        self.type = type
        self.description = description
    }
}

// MARK: - Reasoning (ignored in v0)

public struct ResponsesReasoning: Codable, Sendable, Equatable {
    public var effort: String?
    public var summary: String?

    public init(effort: String? = nil, summary: String? = nil) {
        self.effort = effort
        self.summary = summary
    }
}
