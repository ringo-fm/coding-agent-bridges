import Testing
import Foundation
@testable import ClaudeAdapter

@Suite struct MessagesRequestDecodingTests {
    @Test func decodesStringSystemAndStringContent() throws {
        let json = """
        {"model":"claude-afm-local","max_tokens":128,"system":"You are helpful.","messages":[{"role":"user","content":"hi"}],"stream":true,"temperature":0.5}
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(MessagesRequest.self, from: json)
        #expect(req.model == "claude-afm-local")
        #expect(req.maxTokens == 128)
        #expect(req.stream == true)
        #expect(req.temperature == 0.5)
        #expect(req.system?.flattenedText == "You are helpful.")
        #expect(req.messages.count == 1)
        #expect(req.messages[0].content.allText == "hi")
    }

    @Test func decodesBlockSystemAndBlockContent() throws {
        let json = """
        {"model":"claude-afm-local","max_tokens":128,"system":[{"type":"text","text":"S1"},{"type":"text","text":"S2"}],"messages":[{"role":"user","content":[{"type":"text","text":"hello"},{"type":"text","text":"world"}]}]}
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(MessagesRequest.self, from: json)
        #expect(req.system?.flattenedText == "S1\n\nS2")
        #expect(req.messages[0].content.allText == "hello\nworld")
    }

    @Test func decodesToolResultStringContent() throws {
        let json = """
        {"model":"claude-afm-local","max_tokens":128,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ls output","is_error":false}]}]}
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(MessagesRequest.self, from: json)
        guard case .blocks(let bs) = req.messages[0].content, case .toolResult(let r) = bs[0] else {
            Issue.record("expected tool_result block"); return
        }
        #expect(r.toolUseId == "toolu_1")
        #expect(r.flattenedContent == "ls output")
        #expect(r.isError == false)
    }

    @Test func decodesToolResultBlockContent() throws {
        let json = """
        {"model":"claude-afm-local","max_tokens":128,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"line1"},{"type":"text","text":"line2"}],"is_error":true}]}]}
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(MessagesRequest.self, from: json)
        guard case .blocks(let bs) = req.messages[0].content, case .toolResult(let r) = bs[0] else {
            Issue.record("expected tool_result block"); return
        }
        #expect(r.flattenedContent == "line1\nline2")
        #expect(r.isError == true)
    }

    @Test func toleratesUnknownFields() throws {
        let json = """
        {"model":"claude-afm-local","max_tokens":128,"messages":[{"role":"user","content":"hi"}],"tools":[{"name":"Bash"}],"tool_choice":{"type":"auto"},"thinking":{"type":"enabled","budget_tokens":1024},"metadata":{"user_id":"u1"},"custom_field":123}
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(MessagesRequest.self, from: json)
        #expect(req.toolsPresent == true)
        #expect(req.toolChoicePresent == true)
        #expect(req.thinkingPresent == true)
        #expect(req.messages[0].content.allText == "hi")
    }

    @Test func decodesToolUseAssistantTurn() throws {
        let json = """
        {"model":"claude-afm-local","max_tokens":128,"messages":[{"role":"assistant","content":[{"type":"text","text":"Running it."},{"type":"tool_use","id":"toolu_9","name":"Bash","input":{"command":"ls"}}]}]}
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(MessagesRequest.self, from: json)
        guard case .blocks(let bs) = req.messages[0].content else { Issue.record("expected blocks"); return }
        #expect(bs.count == 2)
        guard case .toolUse(let u) = bs[1] else { Issue.record("expected tool_use"); return }
        #expect(u.name == "Bash")
        #expect(u.id == "toolu_9")
    }

    @Test func decodesThinkingBlock() throws {
        let json = """
        {"model":"claude-afm-local","max_tokens":128,"messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"reasoning here","signature":"sig"}]}]}
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(MessagesRequest.self, from: json)
        guard case .blocks(let bs) = req.messages[0].content, case .thinking(let t) = bs[0] else {
            Issue.record("expected thinking block"); return
        }
        #expect(t == "reasoning here")
    }
}

