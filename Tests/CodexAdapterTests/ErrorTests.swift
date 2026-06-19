import Testing
import Foundation
@testable import CodexAdapter

@Suite("Error mapping and models")
struct ErrorTests {

    @Test("BridgeError codes map correctly")
    func bridgeErrorCodes() {
        #expect(BridgeError.afmUnavailable(reason: "x").code == .afmUnavailable)
        #expect(BridgeError.unsupportedModel("gpt-4").code == .unsupportedModel)
        #expect(BridgeError.unsupportedInputType("input_image").code == .unsupportedInputType)
        #expect(BridgeError.unsupportedToolType("function").code == .unsupportedToolType)
        #expect(BridgeError.generationCancelled.code == .generationCancelled)
        #expect(BridgeError.generationFailed("e").code == .generationFailed)
        #expect(BridgeError.contextTooLarge(inputTokens: 1, limit: 4096).code == .contextTooLarge)
        #expect(BridgeError.unauthorized.code == .unauthorized)
        #expect(BridgeError.invalidRequest("e").code == .invalidRequest)
        #expect(BridgeError.internalError("e").code == .internalError)
        #expect(BridgeError.unsupportedLanguageOrLocale("x").code == .unsupportedLanguageOrLocale)
    }

    @Test("BridgeError http statuses are sensible")
    func bridgeErrorStatuses() {
        #expect(BridgeError.afmUnavailable(reason: "x").httpStatus == 503)
        #expect(BridgeError.unsupportedModel("gpt-4").httpStatus == 400)
        #expect(BridgeError.unauthorized.httpStatus == 401)
        #expect(BridgeError.contextTooLarge(inputTokens: 1, limit: 4096).httpStatus == 413)
        #expect(BridgeError.generationCancelled.httpStatus == 499)
        #expect(BridgeError.generationFailed("e").httpStatus == 500)
        #expect(BridgeError.internalError("e").httpStatus == 500)
    }

    @Test("BridgeError errorObject carries message and code")
    func errorObjectContent() {
        let err = BridgeError.contextTooLarge(inputTokens: 5000, limit: 4096)
        let obj = err.errorObject
        #expect(obj.code == "context_too_large")
        #expect(obj.type == "context_too_large")
        #expect(obj.message.contains("5000"))
        #expect(obj.message.contains("4096"))
    }

    @Test("BridgeError envelope wraps under error key")
    func envelopeShape() throws {
        let err = BridgeError.unauthorized
        let envelope = err.envelope
        let data = try JSONEncoder().encode(envelope)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"error\""))
        #expect(json.contains("\"code\":\"unauthorized\""))
    }

    @Test("SupportedModels accepts canonical and aliases")
    func supportedModels() {
        #expect(SupportedModels.isSupported("apple-foundation-local"))
        #expect(SupportedModels.isSupported("apple-foundation-fast"))
        #expect(SupportedModels.isSupported("apple-foundation-structured"))
        #expect(!SupportedModels.isSupported("gpt-4"))
        #expect(!SupportedModels.isSupported("apple-foundation-local-v2"))
        #expect(SupportedModels.canonical == "apple-foundation-local")
    }

    @Test("ModelsList.default advertises the canonical model")
    func modelsListDefault() {
        let ids = ModelsList.default.data.map(\.id)
        #expect(ids.contains("apple-foundation-local"))
        #expect(ModelsList.default.object == "list")
        #expect(ModelsList.default.data.allSatisfy { $0.object == "model" })
    }

    @Test("ModelsList encodes both data and models fields for Codex compat")
    func modelsListCodexCompat() throws {
        let data = try JSONEncoder().encode(ModelsList.default)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"data\""))
        #expect(json.contains("\"models\""))
    }

    @Test("CompatibilityProfile.codexMinimal is text-only")
    func codexMinimalProfile() {
        let profile = CompatibilityProfile.codexMinimal
        #expect(profile.flags.textGeneration)
        #expect(profile.flags.streaming)
        #expect(!profile.flags.imageInput)
        #expect(!profile.flags.functionCall)
        #expect(!profile.flags.shellCall)
        #expect(!profile.flags.applyPatchCall)
        #expect(profile.usage == .estimated)
    }

    @Test("Diagnostics records ignored fields and unsupported types")
    func diagnosticsAccumulation() {
        var diags = Diagnostics()
        diags.ignore("tools", reason: "text-only")
        diags.unsupportedInput("input_image")
        diags.unsupportedTool("function")
        diags.note("something")
        #expect(diags.ignoredFields.contains("tools"))
        #expect(diags.unsupportedInputTypes == ["input_image"])
        #expect(diags.unsupportedToolTypes == ["function"])
        #expect(diags.notes.contains { $0.contains("something") })
        #expect(!diags.isEmpty)
    }

    @Test("empty Diagnostics isEmpty is true")
    func emptyDiagnostics() {
        #expect(Diagnostics().isEmpty)
    }
}

