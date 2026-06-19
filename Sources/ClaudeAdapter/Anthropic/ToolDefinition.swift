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

