import Testing
import Foundation
@testable import ClaudeAdapter

@Suite struct PromptBuilderTests {
    private func makeRequest(system: String?, turns: [NormalizedTurn]) -> NormalizedRequest {
        NormalizedRequest(
            model: "claude-afm-local",
            systemText: system,
            turns: turns,
            stream: false,
            temperature: nil,
            maxTokens: nil,
            tools: nil,
            toolChoicePresent: false,
            thinkingPresent: false
        )
    }

    @Test func instructionsIncludeHeaderAndSystem() {
        let n = makeRequest(system: "Be terse.", turns: [])
        let instr = TranscriptBuilder.instructions(from: n)
        #expect(instr.contains("Priority rules"))
        #expect(instr.contains("Be terse."))
        #expect(instr.contains("System instructions:"))
    }

    @Test func instructionsOmitSystemWhenEmpty() {
        let n = makeRequest(system: nil, turns: [])
        let instr = TranscriptBuilder.instructions(from: n)
        #expect(instr.contains("Priority rules"))
        #expect(!instr.contains("System instructions:"))
    }

    @Test func conversationRendersRolesAndToolResults() {
        let n = makeRequest(system: nil, turns: [
            NormalizedTurn(role: "user", blocks: [.init(kind: .text("hi"))]),
            NormalizedTurn(role: "assistant", blocks: [.init(kind: .text("hello"))]),
            NormalizedTurn(role: "user", blocks: [.init(kind: .toolResult(ToolResultSegment(toolUseId: "toolu_1", content: "ls output", isError: false)))]),
        ])
        let conv = TranscriptBuilder.conversation(from: n)
        #expect(conv.contains("[user] hi"))
        #expect(conv.contains("[assistant] hello"))
        #expect(conv.contains("[tool_result id=toolu_1 is_error=false]"))
        #expect(conv.contains("ls output"))
        #expect(conv.contains("[/tool_result]"))
    }

    @Test func conversationRendersToolUseMarker() {
        let n = makeRequest(system: nil, turns: [
            NormalizedTurn(role: "assistant", blocks: [.init(kind: .toolUse(name: "Bash", id: "toolu_9", input: nil))]),
        ])
        let conv = TranscriptBuilder.conversation(from: n)
        #expect(conv.contains("[assistant tool_use name=Bash id=toolu_9]"))
    }

    @Test func conversationRendersUnsupportedMarker() {
        let n = makeRequest(system: nil, turns: [
            NormalizedTurn(role: "user", blocks: [.init(kind: .unsupported(type: "image"))]),
        ])
        let conv = TranscriptBuilder.conversation(from: n)
        #expect(conv.contains("[user unsupported_block type=image]"))
    }

    @Test func longAllowedInputStillTruncatesBeforeHardLimit() {
        let conversation = "Conversation:\n[user] " + String(repeating: "x", count: PromptTruncator.maxConversationChars + 100)

        #expect(!PromptTruncator.isTooLarge(instructions: TranscriptBuilder.header, conversation: conversation))
        #expect(PromptTruncator.truncateConversation(conversation).contains("earlier conversation truncated"))
    }
}

