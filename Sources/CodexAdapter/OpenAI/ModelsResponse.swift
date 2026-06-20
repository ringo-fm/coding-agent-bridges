import Foundation

/// GET /v1/models response. Emits two arrays:
/// - `data`: OpenAI-standard model objects (for generic API clients)
/// - `models`: Codex `ModelInfo`-shaped objects (for Codex models-manager)
///
/// Codex requires `models` with many non-standard fields (`slug`,
/// `display_name`, `shell_type`, `truncation_policy`, etc). The `data` array
/// keeps the standard OpenAI shape for other consumers.
public struct ModelsList: Codable, Sendable, Equatable {
    public var object: String
    public var data: [Model]
    public var models: [CodexModelInfo]

    public init(object: String = "list", data: [Model], models: [CodexModelInfo]) {
        self.object = object
        self.data = data
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case object, data, models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.object = try c.decodeIfPresent(String.self, forKey: .object) ?? "list"
        self.data = try c.decodeIfPresent([Model].self, forKey: .data) ?? []
        self.models = try c.decodeIfPresent([CodexModelInfo].self, forKey: .models) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(object, forKey: .object)
        try c.encode(data, forKey: .data)
        try c.encode(models, forKey: .models)
    }

    public static let `default` = ModelsList(
        data: [
            Model(id: "apple-foundation-local", ownedBy: "apple-foundation-models-local"),
            Model(id: "apple-foundation-fast", ownedBy: "apple-foundation-models-local"),
            Model(id: "apple-foundation-structured", ownedBy: "apple-foundation-models-local")
        ],
        models: [
            CodexModelInfo.appleFoundationLocal,
            CodexModelInfo.appleFoundationFast,
            CodexModelInfo.appleFoundationStructured
        ]
    )
}

/// OpenAI-standard model object (for the `data` array).
public struct Model: Codable, Sendable, Equatable {
    public var id: String
    public var object: String
    public var created: Int
    public var owned_by: String

    public init(id: String, object: String = "model", created: Int = 0, ownedBy: String) {
        self.id = id
        self.object = object
        self.created = created
        self.owned_by = ownedBy
    }

    enum CodingKeys: String, CodingKey {
        case id, object, created
        case owned_by
    }
}

/// Codex `ModelInfo`-shaped object. All non-optional fields required by
/// Codex's `ModelsResponse` deserializer are present.
public struct CodexModelInfo: Codable, Sendable, Equatable {
    public var slug: String
    public var display_name: String
    public var description: String?
    public var default_reasoning_level: String?
    public var supported_reasoning_levels: [ReasoningEffortPreset]
    public var shell_type: String
    public var visibility: String
    public var supported_in_api: Bool
    public var priority: Int
    public var availability_nux: String?
    public var upgrade: String?
    public var base_instructions: String
    public var model_messages: ModelMessages?
    public var supports_reasoning_summaries: Bool
    public var default_reasoning_summary: String
    public var support_verbosity: Bool
    public var default_verbosity: String?
    public var apply_patch_tool_type: String?
    public var web_search_tool_type: String
    public var truncation_policy: TruncationPolicy
    public var supports_parallel_tool_calls: Bool
    public var supports_image_detail_original: Bool
    public var experimental_supported_tools: [String]
    // Optional but useful for Codex to respect the 4096 context ceiling.
    public var context_window: Int?
    public var max_context_window: Int?
    public var auto_compact_token_limit: Int?
    public var effective_context_window_percent: Int
    public var input_modalities: [String]
    public var supports_search_tool: Bool

    public struct ReasoningEffortPreset: Codable, Sendable, Equatable {
        public var effort: String
        public var description: String
        public init(effort: String, description: String) {
            self.effort = effort
            self.description = description
        }
    }

    public struct TruncationPolicy: Codable, Sendable, Equatable {
        public var mode: String
        public var limit: Int
        public init(mode: String, limit: Int) {
            self.mode = mode
            self.limit = limit
        }
    }

    public struct ModelMessages: Codable, Sendable, Equatable {
        public var instructions_template: String?
        public var instructions_variables: InstructionsVariables?

        public init(
            instructionsTemplate: String? = "",
            instructionsVariables: InstructionsVariables? = nil
        ) {
            instructions_template = instructionsTemplate
            instructions_variables = instructionsVariables
        }
    }

    public struct InstructionsVariables: Codable, Sendable, Equatable {
        public var personality_default: String?
        public var personality_friendly: String?
        public var personality_pragmatic: String?
    }

    public init(
        slug: String,
        display_name: String,
        description: String? = nil,
        default_reasoning_level: String? = nil,
        supported_reasoning_levels: [ReasoningEffortPreset] = [],
        shell_type: String = "shell_command",
        visibility: String = "list",
        supported_in_api: Bool = true,
        priority: Int = 1,
        availability_nux: String? = nil,
        upgrade: String? = nil,
        base_instructions: String = "",
        model_messages: ModelMessages? = ModelMessages(),
        supports_reasoning_summaries: Bool = false,
        default_reasoning_summary: String = "none",
        support_verbosity: Bool = false,
        default_verbosity: String? = nil,
        apply_patch_tool_type: String? = "freeform",
        web_search_tool_type: String = "text",
        truncation_policy: TruncationPolicy,
        supports_parallel_tool_calls: Bool = false,
        supports_image_detail_original: Bool = false,
        experimental_supported_tools: [String] = [],
        context_window: Int? = 4096,
        max_context_window: Int? = 4096,
        auto_compact_token_limit: Int? = 3072,
        effective_context_window_percent: Int = 75,
        input_modalities: [String] = ["text"],
        supports_search_tool: Bool = false
    ) {
        self.slug = slug
        self.display_name = display_name
        self.description = description
        self.default_reasoning_level = default_reasoning_level
        self.supported_reasoning_levels = supported_reasoning_levels
        self.shell_type = shell_type
        self.visibility = visibility
        self.supported_in_api = supported_in_api
        self.priority = priority
        self.availability_nux = availability_nux
        self.upgrade = upgrade
        self.base_instructions = base_instructions
        self.model_messages = model_messages
        self.supports_reasoning_summaries = supports_reasoning_summaries
        self.default_reasoning_summary = default_reasoning_summary
        self.support_verbosity = support_verbosity
        self.default_verbosity = default_verbosity
        self.apply_patch_tool_type = apply_patch_tool_type
        self.web_search_tool_type = web_search_tool_type
        self.truncation_policy = truncation_policy
        self.supports_parallel_tool_calls = supports_parallel_tool_calls
        self.supports_image_detail_original = supports_image_detail_original
        self.experimental_supported_tools = experimental_supported_tools
        self.context_window = context_window
        self.max_context_window = max_context_window
        self.auto_compact_token_limit = auto_compact_token_limit
        self.effective_context_window_percent = effective_context_window_percent
        self.input_modalities = input_modalities
        self.supports_search_tool = supports_search_tool
    }

    public static let appleFoundationLocal = CodexModelInfo(
        slug: "apple-foundation-local",
        display_name: "Apple Foundation Models (Local)",
        description: "On-device Apple Foundation Models backend for bounded coding tasks.",
        shell_type: "shell_command",
        visibility: "list",
        priority: 1,
        truncation_policy: .init(mode: "tokens", limit: 4096),
        context_window: 4096
    )

    public static let appleFoundationFast = CodexModelInfo(
        slug: "apple-foundation-fast",
        display_name: "Apple Foundation Models Fast (Local)",
        description: "On-device Apple Foundation Models backend optimized for short tasks.",
        shell_type: "shell_command",
        visibility: "list",
        priority: 2,
        truncation_policy: .init(mode: "tokens", limit: 4096),
        context_window: 4096
    )

    public static let appleFoundationStructured = CodexModelInfo(
        slug: "apple-foundation-structured",
        display_name: "Apple Foundation Models Structured (Local)",
        description: "On-device Apple Foundation Models backend with structured output support.",
        shell_type: "shell_command",
        visibility: "list",
        priority: 3,
        truncation_policy: .init(mode: "tokens", limit: 4096),
        context_window: 4096
    )
}

/// Models the bridge accepts (the canonical id plus aliases).
public enum SupportedModels {
    public static let canonical = "apple-foundation-local"
    public static let aliases: Set<String> = [
        "apple-foundation-local",
        "apple-foundation-fast",
        "apple-foundation-structured"
    ]

    public static func isSupported(_ model: String) -> Bool {
        aliases.contains(model)
    }
}
