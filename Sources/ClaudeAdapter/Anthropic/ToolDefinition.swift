import Foundation
import AgentBridgeCore

struct ToolDefinition: Codable, Sendable {
    let name: String
    let description: String?
    let inputSchema: ToolInputSchema?

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }

    var summary: String {
        var s = "- \(name)"
        if let desc = description, !desc.isEmpty {
            let short = String(desc.prefix(200))
            s += ": \(short)"
        }
        if let schema = inputSchema, let props = schema.properties {
            for (k, v) in props {
                let req = schema.required?.contains(k) ?? false
                s += "\n  \(k): \(v.type ?? "any")\(req ? " (required)" : "")"
            }
        }
        return s
    }

    var compactSummary: String {
        var value = "- \(name)"
        if let description, !description.isEmpty {
            value += ": " + String(description.prefix(160))
        }
        return value
    }

    var selectedSchemaPrompt: String {
        var lines = ["Selected tool: \(name)"]
        if let description, !description.isEmpty { lines.append("Description: \(description)") }
        lines.append("Input schema:")
        lines.append("type: \(inputSchema?.type ?? "object")")
        if let properties = inputSchema?.properties {
            for key in properties.keys.sorted() {
                guard let property = properties[key] else { continue }
                let required = inputSchema?.required?.contains(key) ?? false
                var line = "- \(key): \(property.type ?? "any")"
                if required { line += " (required)" }
                if let description = property.description, !description.isEmpty {
                    line += " — \(description)"
                }
                lines.append(line)
            }
        }
        lines.append("Return only a JSON object in the arguments field. Do not call or execute the tool.")
        return lines.joined(separator: "\n")
    }

    var agentDefinition: AgentToolDefinition {
        let schema = inputSchema.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"type":"object","properties":{}}"#
        return AgentToolDefinition(
            name: name,
            description: description ?? "Tool: \(name)",
            inputSchemaJSON: schema
        )
    }
}

struct ToolInputSchema: Codable, Sendable {
    let type: String?
    let properties: [String: ToolProperty]?
    let required: [String]?
}

struct ToolProperty: Codable, Sendable {
    let type: String?
    let description: String?
    let properties: [String: ToolProperty]?
    let required: [String]?
    let items: ToolPropertyBox?
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items
        case enumValues = "enum"
    }

    init(
        type: String?,
        description: String?,
        properties: [String: ToolProperty]? = nil,
        required: [String]? = nil,
        items: ToolProperty? = nil,
        enumValues: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.items = items.map(ToolPropertyBox.init)
        self.enumValues = enumValues
    }
}

final class ToolPropertyBox: Codable, @unchecked Sendable {
    let value: ToolProperty
    init(_ value: ToolProperty) { self.value = value }
    required init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(ToolProperty.self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct ToolDefinitions: Decodable {
    let tools: [ToolDefinition]?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.tools = try c.decode([ToolDefinition].self)
    }
}
