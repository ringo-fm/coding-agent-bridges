import XCTest
@testable import AgentBridgeCore

final class AgentBridgeCoreTests: XCTestCase {
    func testGenerationRequestDefaults() {
        let request = AgentGenerationRequest(
            model: "apple-foundation-local",
            messages: [AgentMessage(role: .user, text: "Hello")]
        )

        XCTAssertEqual(request.model, "apple-foundation-local")
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertFalse(request.stream)
    }
}
