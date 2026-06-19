// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "coding-agent-bridges",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "AgentBridgeCore", targets: ["AgentBridgeCore"]),
        .library(name: "AFMBackend", targets: ["AFMBackend"]),
        .library(name: "BridgeHTTP", targets: ["BridgeHTTP"]),
        .library(name: "CodexAdapter", targets: ["CodexAdapter"]),
        .library(name: "ClaudeAdapter", targets: ["ClaudeAdapter"]),
        .executable(name: "codex-afm-bridge", targets: ["CodexAFMBridge"]),
        .executable(name: "claude-afm-bridge", targets: ["ClaudeAFMBridge"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            from: "2.25.0"
        ),
    ],
    targets: [
        .target(name: "AgentBridgeCore"),
        .target(
            name: "AFMBackend",
            dependencies: ["AgentBridgeCore"]
        ),
        .target(
            name: "BridgeHTTP",
            dependencies: [
                "AgentBridgeCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .target(
            name: "CodexAdapter",
            dependencies: [
                "AgentBridgeCore",
                "AFMBackend",
                "BridgeHTTP",
            ]
        ),
        .target(
            name: "ClaudeAdapter",
            dependencies: [
                "AgentBridgeCore",
                "AFMBackend",
                "BridgeHTTP",
            ]
        ),
        .executableTarget(
            name: "CodexAFMBridge",
            dependencies: ["CodexAdapter"]
        ),
        .executableTarget(
            name: "ClaudeAFMBridge",
            dependencies: ["ClaudeAdapter"]
        ),
        .testTarget(
            name: "AgentBridgeCoreTests",
            dependencies: ["AgentBridgeCore"]
        ),
    ]
)
