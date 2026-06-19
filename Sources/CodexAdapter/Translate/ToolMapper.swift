import Foundation
import FoundationModels

/// Converts OpenAI Responses API tool definitions into AFM `BridgedTool` objects
/// with `DynamicGenerationSchema` parameters.
///
/// OpenAI tool shape:
/// ```
/// { "type": "function", "name": "read_file",
///   "description": "Read a file",
///   "parameters": { "type": "object",
///     "properties": { "path": { "type": "string", "description": "..." } },
///     "required": ["path"] } }
/// ```
///
/// AFM tool shape: `BridgedTool` with `GenerationSchema` built from
/// `DynamicGenerationSchema`.
public enum ToolMapper {
    /// Map an array of OpenAI tool definitions to a `BridgedToolRegistry`.
    /// Returns nil if no valid tools could be constructed.
    public static func map(_ tools: [ResponsesTool]) -> BridgedToolRegistry? {
        let bridged: [BridgedTool] = tools.compactMap { mapOne($0) }
        if bridged.isEmpty { return nil }
        return BridgedToolRegistry(tools: bridged)
    }

    /// Map a single OpenAI tool to a `BridgedTool`.
    static func mapOne(_ tool: ResponsesTool) -> BridgedTool? {
        guard tool.type == "function" || tool.type == "local_shell" || tool.type == "apply_patch" else {
            return nil
        }

        let name = tool.name ?? tool.type
        let description = tool.description ?? "Tool: \(name)"

        let schema: GenerationSchema
        if let params = tool.parameters {
            schema = buildSchema(name: name, description: description, params: params)
        } else {
            // Tools without parameters (e.g. apply_patch with inline content).
            schema = buildEmptySchema(name: name, description: description)
        }

        return BridgedTool(name: name, description: description, parameters: schema)
    }

    // MARK: - Schema construction

    /// Build a `GenerationSchema` from OpenAI tool parameters (JSON-Schema-like).
    private static func buildSchema(
        name: String,
        description: String,
        params: ResponsesToolParameters
    ) -> GenerationSchema {
        let properties: [DynamicGenerationSchema.Property] = (params.properties ?? [:])
            .map { propName, prop in
                let propSchema = buildPropertySchema(
                    name: propName,
                    description: prop.description,
                    type: prop.type ?? "string"
                )
                let isOptional = !(params.required ?? []).contains(propName)
                return DynamicGenerationSchema.Property(
                    name: propName,
                    description: prop.description,
                    schema: propSchema,
                    isOptional: isOptional
                )
            }

        let dynamic = DynamicGenerationSchema(
            name: name,
            description: description,
            properties: properties
        )

        do {
            return try GenerationSchema(root: dynamic, dependencies: [])
        } catch {
            // Fallback: empty schema
            return buildEmptySchema(name: name, description: description)
        }
    }

    /// Map an OpenAI property type to a `DynamicGenerationSchema`.
    private static func buildPropertySchema(
        name: String,
        description: String?,
        type: String
    ) -> DynamicGenerationSchema {
        switch type.lowercased() {
        case "string":
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "array":
            return DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    /// Build a minimal schema for tools with no parameters.
    private static func buildEmptySchema(name: String, description: String) -> GenerationSchema {
        let dynamic = DynamicGenerationSchema(
            name: name,
            description: description,
            properties: [
                DynamicGenerationSchema.Property(
                    name: "input",
                    description: "Tool input",
                    schema: DynamicGenerationSchema(type: String.self),
                    isOptional: true
                )
            ]
        )
        return try! GenerationSchema(root: dynamic, dependencies: [])
    }
}

