import Foundation

struct ToolDefinition: Decodable {
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
}

struct ToolInputSchema: Decodable {
    let type: String?
    let properties: [String: ToolProperty]?
    let required: [String]?
}

struct ToolProperty: Decodable {
    let type: String?
    let description: String?
}

struct ToolDefinitions: Decodable {
    let tools: [ToolDefinition]?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.tools = try c.decode([ToolDefinition].self)
    }
}
