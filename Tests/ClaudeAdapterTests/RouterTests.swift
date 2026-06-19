import Testing
import Foundation
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import NIOCore
@testable import ClaudeAdapter

@Suite struct RouterTests {
    private func makeApp() async throws -> some ApplicationProtocol {
        try await buildApplication(config: BridgeConfig(host: "127.0.0.1", port: 0, authToken: "secret", logLevel: .warning, debug: false))
    }

    @Test func healthEndpoint() async throws {
        let app = try await makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"status\":\"ok\""))
                #expect(body.contains("\"service\":\"claude-afm-bridge\""))
            }
        }
    }

    @Test func modelsEndpointRequiresAuth() async throws {
        let app = try await makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                #expect(response.status == .unauthorized)
                let body = String(buffer: response.body)
                #expect(body.contains("\"type\":\"error\""))
                #expect(body.contains("\"authentication_error\""))
            }

            let headers: HTTPFields = [.init("x-api-key")!: "secret"]
            try await client.execute(uri: "/v1/models", method: .get, headers: headers) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("claude-afm-local"))
                #expect(body.contains("\"display_name\":\"Apple Foundation Local\""))
            }
        }
    }

    @Test func messagesRejectsUnsupportedModel() async throws {
        let app = try await makeApp()
        let headers: HTTPFields = [
            .contentType: "application/json",
            .init("x-api-key")!: "secret",
        ]
        let body = "{\"model\":\"gpt-4o\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/messages", method: .post, headers: headers, body: ByteBuffer(string: body)) { response in
                #expect(response.status == .notFound)
                let s = String(buffer: response.body)
                #expect(s.contains("\"not_found_error\""))
                #expect(response.headers[HTTPField.Name("x-afm-error-code")!] == "unsupported_model")
            }
        }
    }

    @Test func countTokensReturnsShape() async throws {
        let app = try await makeApp()
        let headers: HTTPFields = [
            .contentType: "application/json",
            .init("x-api-key")!: "secret",
        ]
        let body = "{\"model\":\"claude-afm-local\",\"messages\":[{\"role\":\"user\",\"content\":\"hello world\"}]}"
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/messages/count_tokens", method: .post, headers: headers, body: ByteBuffer(string: body)) { response in
                #expect(response.status == .ok)
                let s = String(buffer: response.body)
                #expect(s.contains("input_tokens"))
            }
        }
    }

    @Test func messagesRejectsInputsAboveHardContextLimit() async throws {
        let app = try await makeApp()
        let headers: HTTPFields = [
            .contentType: "application/json",
            .init("x-api-key")!: "secret",
        ]
        let huge = String(repeating: "x", count: PromptTruncator.hardInputChars + 1)
        let body = "{\"model\":\"claude-afm-local\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"\(huge)\"}]}"

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/messages", method: .post, headers: headers, body: ByteBuffer(string: body)) { response in
                #expect(response.status == .badRequest)
                let s = String(buffer: response.body)
                #expect(s.contains("\"invalid_request_error\""))
                #expect(response.headers[HTTPField.Name("x-afm-error-code")!] == "context_too_large")
            }
        }
    }

    @Test func countTokensRejectsInputsAboveHardContextLimit() async throws {
        let app = try await makeApp()
        let headers: HTTPFields = [
            .contentType: "application/json",
            .init("x-api-key")!: "secret",
        ]
        let huge = String(repeating: "x", count: PromptTruncator.hardInputChars + 1)
        let body = "{\"model\":\"claude-afm-local\",\"messages\":[{\"role\":\"user\",\"content\":\"\(huge)\"}]}"

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/messages/count_tokens", method: .post, headers: headers, body: ByteBuffer(string: body)) { response in
                #expect(response.status == .badRequest)
                let s = String(buffer: response.body)
                #expect(s.contains("\"invalid_request_error\""))
                #expect(response.headers[HTTPField.Name("x-afm-error-code")!] == "context_too_large")
            }
        }
    }
}

