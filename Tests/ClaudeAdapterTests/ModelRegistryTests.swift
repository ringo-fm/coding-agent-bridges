import Testing
@testable import ClaudeAdapter

@Suite struct ModelRegistryTests {
    @Test func supportsPrimaryAndAliases() {
        #expect(ModelRegistry.resolve("claude-afm-local") == "claude-afm-local")
        #expect(ModelRegistry.resolve("claude-afm-local-v2") != nil)
        #expect(ModelRegistry.resolve("claude-3-5-haiku-latest") != nil)
        #expect(ModelRegistry.resolve("claude-3-5-sonnet-20241022") != nil)
        #expect(ModelRegistry.resolve("claude-3-opus-latest") != nil)
        #expect(ModelRegistry.resolve("claude-sonnet-4-20250514") != nil)
    }

    @Test func rejectsUnknownModels() {
        #expect(ModelRegistry.resolve("gpt-4o") == nil)
        #expect(ModelRegistry.resolve("gemini-1.5-pro") == nil)
        #expect(ModelRegistry.resolve("llama3") == nil)
    }

    @Test func isSupportedBoolean() {
        #expect(ModelRegistry.isSupported("claude-afm-local") == true)
        #expect(ModelRegistry.isSupported("random-model") == false)
    }
}

