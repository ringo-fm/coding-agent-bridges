import Testing
import Foundation
@testable import CodexAdapter

@Suite("Prompt mapping")
struct PromptMappingTests {

    @Test("input string becomes one user message")
    func inputStringBecomesUserMessage() {
        let request = ResponsesCreateRequest(model: "apple-foundation-local", input: .text("Hello"))
        let normalized = InputNormalizer.normalize(request)
        #expect(normalized.messages.count == 1)
        #expect(normalized.messages.first?.role == .user)
        #expect(normalized.messages.first?.text == "Hello")
        #expect(normalized.instructions == nil)
    }

    @Test("input items with mixed roles are normalized")
    func inputItemsMixedRoles() {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            instructions: "Be concise.",
            input: .items([
                .user(text: "Hi"),
                ResponsesInputItem(type: "message", role: "assistant", content: [.text("Hello there")]),
                ResponsesInputItem(type: "message", role: "developer", content: [.text("Use tabs")]),
                ResponsesInputItem(type: "message", role: "user", content: [.text("Explain")])
            ])
        )
        let normalized = InputNormalizer.normalize(request)
        #expect(normalized.instructions == "Be concise.")
        #expect(normalized.messages.count == 4)
        #expect(normalized.messages[0].role == .user)
        #expect(normalized.messages[1].role == .assistant)
        #expect(normalized.messages[2].role == .developer)
        #expect(normalized.messages[3].role == .user)
        #expect(normalized.messages[1].text == "Hello there")
    }

    @Test("input_image is recorded as unsupported input type")
    func inputImageRecordedAsUnsupported() {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .items([
                ResponsesInputItem(type: "message", role: "user", content: [
                    .text("describe this"),
                    .image("file:///tmp/x.png")
                ])
            ])
        )
        let normalized = InputNormalizer.normalize(request)
        #expect(normalized.diagnostics.unsupportedInputTypes.contains("input_image"))
        // The text part survives; the image part is dropped.
        #expect(normalized.messages.count == 1)
        #expect(normalized.messages.first?.text == "describe this")
    }

    @Test("non-message item types are recorded as unsupported or ignored")
    func nonMessageItemsRecorded() {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .items([
                ResponsesInputItem(type: "function_call", role: "assistant", content: nil),
                ResponsesInputItem(type: "reasoning", role: "assistant", content: nil),
                .user(text: "ok")
            ])
        )
        let normalized = InputNormalizer.normalize(request)
        // function_call is ignored (not enabled), reasoning is unsupported
        #expect(normalized.diagnostics.ignoredFields.contains("function_call"))
        #expect(normalized.diagnostics.unsupportedInputTypes.contains("reasoning"))
        #expect(normalized.messages.count == 1)
    }

    @Test("tools are ignored and recorded")
    func toolsIgnoredAndRecorded() {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .text("hi"),
            tools: [ResponsesTool(type: "function", name: "shell")]
        )
        let normalized = InputNormalizer.normalize(request)
        #expect(normalized.diagnostics.unsupportedToolTypes.contains("function"))
        #expect(normalized.diagnostics.ignoredFields.contains("tools"))
    }

    @Test("reasoning and previous_response_id are ignored")
    func reasoningAndPreviousResponseIgnored() {
        let request = ResponsesCreateRequest(
            model: "apple-foundation-local",
            input: .text("hi"),
            reasoning: ResponsesReasoning(effort: "high"),
            previous_response_id: "resp_abc"
        )
        let normalized = InputNormalizer.normalize(request)
        #expect(normalized.diagnostics.ignoredFields.contains("reasoning"))
        #expect(normalized.diagnostics.ignoredFields.contains("previous_response_id"))
    }

    @Test("PromptBuilder includes preamble, instructions, and conversation")
    func promptBuilderContent() {
        let normalized = NormalizedInput(
            instructions: "Be helpful.",
            messages: [
                NormalizedMessage(role: .system, text: "System rule"),
                NormalizedMessage(role: .developer, text: "Dev rule"),
                NormalizedMessage(role: .user, text: "Question?"),
                NormalizedMessage(role: .assistant, text: "Answer.")
            ],
            diagnostics: Diagnostics()
        )
        let prompt = PromptBuilder.build(from: normalized)
        #expect(prompt.contains(PromptBuilder.preamble))
        #expect(prompt.contains("Be helpful."))
        #expect(prompt.contains("System rule"))
        #expect(prompt.contains("Dev rule"))
        #expect(prompt.contains("[user] Question?"))
        #expect(prompt.contains("[assistant] Answer."))
        #expect(prompt.contains("Conversation:"))
    }

    @Test("PromptBuilder omits empty sections")
    func promptBuilderOmitsEmptySections() {
        let normalized = NormalizedInput(
            instructions: nil,
            messages: [NormalizedMessage(role: .user, text: "Hi")],
            diagnostics: Diagnostics()
        )
        let prompt = PromptBuilder.build(from: normalized)
        #expect(prompt.contains("[user] Hi"))
        #expect(!prompt.contains("Developer instructions:"))
        // System instructions section appears only because of instructions=nil
        #expect(!prompt.contains("System instructions:"))
    }

    @Test("unknown role falls back to user")
    func unknownRoleFallsBackToUser() {
        #expect(NormalizedMessage.Role.from("narrator") == .user)
        #expect(NormalizedMessage.Role.from(nil) == .user)
        #expect(NormalizedMessage.Role.from("SYSTEM") == .system)
    }

    @Test("buildBounded returns full prompt when under budget")
    func buildBoundedUnderBudget() {
        let normalized = NormalizedInput(
            instructions: "Be brief.",
            messages: [NormalizedMessage(role: .user, text: "Hi")],
            diagnostics: Diagnostics()
        )
        let result = PromptBuilder.buildBounded(from: normalized, maxInputTokens: 1000)
        #expect(!result.truncated)
        #expect(result.prompt.contains("Hi"))
        #expect(result.estimatedTokens < 1000)
    }

    @Test("buildBounded truncates when over budget and keeps preamble")
    func buildBoundedTruncates() {
        let longText = String(repeating: "This is a long system instruction. ", count: 200)
        let normalized = NormalizedInput(
            instructions: longText,
            messages: [
                NormalizedMessage(role: .user, text: String(repeating: "Question detail. ", count: 100)),
                NormalizedMessage(role: .assistant, text: String(repeating: "Answer detail. ", count: 100)),
                NormalizedMessage(role: .user, text: "Final question?")
            ],
            diagnostics: Diagnostics()
        )
        let result = PromptBuilder.buildBounded(from: normalized, maxInputTokens: 100)
        #expect(result.truncated)
        #expect(result.estimatedTokens <= 100)
        // Preamble is always preserved.
        #expect(result.prompt.contains(PromptBuilder.preamble))
        // The most recent user message is kept.
        #expect(result.prompt.contains("Final question?"))
    }

    @Test("buildBounded hard-truncates to fit even with huge instructions")
    func buildBoundedHardTruncate() {
        let huge = String(repeating: "x", count: 10_000)
        let normalized = NormalizedInput(
            instructions: huge,
            messages: [NormalizedMessage(role: .user, text: huge)],
            diagnostics: Diagnostics()
        )
        let result = PromptBuilder.buildBounded(from: normalized, maxInputTokens: 200)
        #expect(result.truncated)
        #expect(result.estimatedTokens <= 200)
        #expect(result.prompt.contains(PromptBuilder.preamble))
    }
}

