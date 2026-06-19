import Foundation

/// A normalized conversation message after flattening OpenAI Responses input.
public struct NormalizedMessage: Sendable, Equatable {
    public let role: Role
    public let text: String

    public enum Role: String, Sendable, Equatable {
        case system
        case developer
        case user
        case assistant
        case tool

        /// Map an OpenAI role string to a normalized role. Unknown roles fall
        /// back to `.user` (and are recorded as ignored by the caller).
        public static func from(_ raw: String?) -> Role {
            switch (raw ?? "").lowercased() {
            case "system": return .system
            case "developer": return .developer
            case "user": return .user
            case "assistant": return .assistant
            case "tool": return .tool
            default: return .user
            }
        }
    }

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// A captured tool call from the input (function_call item from a previous turn).
public struct NormalizedToolCall: Sendable, Equatable {
    public let callID: String
    public let name: String
    public let arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

/// A captured tool call output from the input (function_call_output item).
public struct NormalizedToolOutput: Sendable, Equatable {
    public let callID: String
    public let output: String

    public init(callID: String, output: String) {
        self.callID = callID
        self.output = output
    }
}

/// Result of normalizing a Responses API request.
public struct NormalizedInput: Sendable {
    public let instructions: String?
    public let messages: [NormalizedMessage]
    public var toolCalls: [NormalizedToolCall]
    public var toolOutputs: [NormalizedToolOutput]
    public var diagnostics: Diagnostics

    public init(
        instructions: String?,
        messages: [NormalizedMessage],
        toolCalls: [NormalizedToolCall] = [],
        toolOutputs: [NormalizedToolOutput] = [],
        diagnostics: Diagnostics
    ) {
        self.instructions = instructions
        self.messages = messages
        self.toolCalls = toolCalls
        self.toolOutputs = toolOutputs
        self.diagnostics = diagnostics
    }
}

/// Converts an OpenAI Responses API request body into a normalized transcript.
/// Drops unsupported input types (images/files) and records diagnostics.
/// When `flags.functionCall` is true, function_call and function_call_output
/// items are captured and passed through to the prompt.
public enum InputNormalizer {
    public static func normalize(
        _ request: ResponsesCreateRequest,
        flags: FeatureFlags = .codexMinimal
    ) -> NormalizedInput {
        var diagnostics = Diagnostics()

        // Tools handling: accept and pass through when function-call is enabled;
        // otherwise record as ignored.
        if let tools = request.tools, !tools.isEmpty {
            if flags.functionCall {
                diagnostics.note("tools: \(tools.count) tool(s) accepted")
            } else {
                for tool in tools {
                    diagnostics.unsupportedTool(tool.type)
                }
                diagnostics.ignore("tools", reason: "tools ignored in text-only profile")
            }
        }
        if request.reasoning != nil {
            diagnostics.ignore("reasoning", reason: "reasoning not supported by AFM")
        }
        if request.previous_response_id != nil {
            diagnostics.ignore("previous_response_id", reason: "session not retained in MVP")
        }
        if request.store != nil {
            diagnostics.ignore("store", reason: "storage controlled by caller")
        }
        if request.metadata != nil {
            diagnostics.ignore("metadata")
        }

        var messages: [NormalizedMessage] = []
        var toolCalls: [NormalizedToolCall] = []
        var toolOutputs: [NormalizedToolOutput] = []

        for item in request.input.asItems {
            let itemType = item.type ?? "message"

            switch itemType {
            case "message":
                let role = NormalizedMessage.Role.from(item.role)
                guard let parts = item.content, !parts.isEmpty else { continue }

                var textParts: [String] = []
                for part in parts {
                    switch part.type {
                    case "input_text", "text":
                        if let t = part.text, !t.isEmpty {
                            textParts.append(t)
                        }
                    case "input_image":
                        if flags.imageInput {
                            diagnostics.note("input_image: accepted (flag enabled)")
                        } else {
                            diagnostics.unsupportedInput("input_image")
                        }
                    case "input_file":
                        if flags.fileInput {
                            diagnostics.note("input_file: accepted (flag enabled)")
                        } else {
                            diagnostics.unsupportedInput("input_file")
                        }
                    default:
                        diagnostics.unsupportedInput(part.type)
                    }
                }

                let text = textParts.joined(separator: "\n")
                if !text.isEmpty {
                    messages.append(NormalizedMessage(role: role, text: text))
                }

            case "function_call":
                if flags.functionCall {
                    if let name = item.name, let args = item.arguments, let callID = item.call_id ?? item.id {
                        toolCalls.append(NormalizedToolCall(
                            callID: callID, name: name, arguments: args
                        ))
                    }
                } else {
                    diagnostics.ignore("function_call", reason: "function calls not enabled")
                }

            case "function_call_output":
                if flags.functionCall {
                    if let callID = item.call_id, let output = item.arguments ?? item.name {
                        toolOutputs.append(NormalizedToolOutput(
                            callID: callID, output: output
                        ))
                    }
                } else {
                    diagnostics.ignore("function_call_output", reason: "function calls not enabled")
                }

            default:
                diagnostics.unsupportedInput(itemType)
            }
        }

        return NormalizedInput(
            instructions: request.instructions,
            messages: messages,
            toolCalls: toolCalls,
            toolOutputs: toolOutputs,
            diagnostics: diagnostics
        )
    }
}

