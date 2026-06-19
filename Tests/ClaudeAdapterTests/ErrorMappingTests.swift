import Testing
import FoundationModels
@testable import ClaudeAdapter

@Suite struct ErrorMappingTests {
    @Test func unsupportedModelShape() {
        let e = AnthropicError.unsupportedModel("nope")
        #expect(e.errorType == "not_found_error")
        #expect(e.code == .unsupportedModel)
    }

    @Test func afmUnavailableShape() {
        let e = AnthropicError.afmUnavailable("unavailable")
        #expect(e.errorType == "invalid_request_error")
        #expect(e.code == .afmUnavailable)
    }

    @Test func unauthorizedShape() {
        let e = AnthropicError.unauthorized("no key")
        #expect(e.errorType == "authentication_error")
        #expect(e.code == .authenticationError)
    }

    @Test func mapsGenerationErrors() {
        let ctx = LanguageModelSession.GenerationError.Context(debugDescription: "x")
        #expect(ErrorMapper.map(LanguageModelSession.GenerationError.exceededContextWindowSize(ctx)).code == .contextTooLarge)
        #expect(ErrorMapper.map(LanguageModelSession.GenerationError.assetsUnavailable(ctx)).code == .afmUnavailable)
        #expect(ErrorMapper.map(LanguageModelSession.GenerationError.guardrailViolation(ctx)).code == .guardrailViolation)
        #expect(ErrorMapper.map(LanguageModelSession.GenerationError.rateLimited(ctx)).code == .rateLimited)
        #expect(ErrorMapper.map(LanguageModelSession.GenerationError.concurrentRequests(ctx)).code == .rateLimited)
        #expect(ErrorMapper.map(LanguageModelSession.GenerationError.decodingFailure(ctx)).code == .generationFailed)
    }

    @Test func mapsRefusalAsGenerationFailedWhenNotHandled() {
        let ctx = LanguageModelSession.GenerationError.Context(debugDescription: "x")
        let refusal = LanguageModelSession.GenerationError.Refusal(transcriptEntries: [])
        let e = ErrorMapper.map(LanguageModelSession.GenerationError.refusal(refusal, ctx))
        #expect(e.code == .generationFailed)
    }

    @Test func mapsUnknownError() {
        struct CustomError: Error {}
        #expect(ErrorMapper.map(CustomError()).code == .generationFailed)
    }

    @Test func passesThroughAnthropicError() {
        let original = AnthropicError.contextTooLarge("big")
        #expect(ErrorMapper.map(original).code == .contextTooLarge)
    }
}

