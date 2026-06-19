import Foundation

struct ModelsResponse: Codable {
    let data: [Model]
    let hasMore: Bool
    let firstId: String?
    let lastId: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case firstId = "first_id"
        case lastId = "last_id"
    }

    struct Model: Codable {
        let id: String
        let type: String
        let displayName: String
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case id, type
            case displayName = "display_name"
            case createdAt = "created_at"
        }
    }
}

extension ModelsResponse {
    static func make() -> ModelsResponse {
        let id = ModelRegistry.primaryModel
        let model = Model(id: id, type: "model", displayName: "Apple Foundation Local", createdAt: "2026-06-18T00:00:00Z")
        return ModelsResponse(data: [model], hasMore: false, firstId: id, lastId: id)
    }
}

struct HealthResponse: Codable {
    let status: String
    let service: String
    let afmAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case status, service
        case afmAvailable = "afm_available"
    }
}

