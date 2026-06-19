import Foundation
import FoundationModels
import Synchronization

/// A captured tool call from AFM. Each entry records the tool name and the
/// arguments as a JSON string (extracted from `GeneratedContent`).
public struct CapturedToolCall: Sendable, Equatable {
    public let name: String
    public let argumentsJSON: String

    public init(name: String, argumentsJSON: String) {
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// A tool that captures AFM's call decisions without executing anything.
/// When AFM decides to call a tool, `call(arguments:)` records the call and
/// returns a placeholder string. The bridge then emits a `function_call`
/// Responses API item so Codex can execute the tool.
///
/// This follows the design doc's core rule: the bridge translates model output,
/// it does not execute commands.
final public class BridgedTool: Tool, @unchecked Sendable {
    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    public let includesSchemaInInstructions: Bool = true

    /// Captured calls from the current generation. Accessed atomically.
    private let capturedCalls = Mutex<[CapturedToolCall]>([])

    public init(name: String, description: String, parameters: GenerationSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        let json = arguments.jsonString
        capturedCalls.withLock { $0.append(CapturedToolCall(name: name, argumentsJSON: json)) }
        // Return a placeholder so AFM continues. The actual tool execution
        // is delegated to Codex via the function_call output item.
        return "[Tool '\(name)' call captured. Execution delegated to Codex. The result will be provided in the next turn.]"
    }

    /// Drain and return all captured calls.
    public func drainCapturedCalls() -> [CapturedToolCall] {
        capturedCalls.withLock { calls in
            let result = calls
            calls = []
            return result
        }
    }
}

/// Registry of all bridged tools for a single request. Owns the `BridgedTool`
/// instances and provides access to captured calls after generation.
public final class BridgedToolRegistry: @unchecked Sendable {
    private let tools: [BridgedTool]

    public init(tools: [BridgedTool]) {
        self.tools = tools
    }

    public var afmTools: [any Tool] {
        tools.map { $0 as any Tool }
    }

    /// Drain captured calls from all tools, preserving order by tool index.
    public func drainAllCapturedCalls() -> [CapturedToolCall] {
        tools.flatMap { $0.drainCapturedCalls() }
    }
}

