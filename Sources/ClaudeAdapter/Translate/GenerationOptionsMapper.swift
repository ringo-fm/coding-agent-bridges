import FoundationModels

enum GenerationOptionsMapper {
    static func map(maxTokens: Int?, temperature: Double?) -> GenerationOptions {
        GenerationOptions(
            temperature: temperature,
            maximumResponseTokens: maxTokens
        )
    }
}

