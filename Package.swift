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
        .library(name: "RingoCore", targets: ["RingoCore"]),
        .executable(name: "ringo", targets: ["RingoCLI"]),
        .executable(name: "codex-afm-bridge", targets: ["CodexAFMBridge"]),
        .executable(name: "claude-afm-bridge", targets: ["ClaudeAFMBridge"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            from: "2.25.0"
        ),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.86.0"),
    ],
    targets: [
        .target(
            name: "AgentBridgeCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "AFMBackend",
            dependencies: ["AgentBridgeCore"]
        ),
        .target(
            name: "BridgeHTTP",
            dependencies: [
                "AgentBridgeCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "CodexAdapter",
            dependencies: [
                "AgentBridgeCore",
                "AFMBackend",
                "BridgeHTTP",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "ClaudeAdapter",
            dependencies: [
                "AgentBridgeCore",
                "AFMBackend",
                "BridgeHTTP",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "CodexAFMBridge",
            dependencies: [
                "CodexAdapter",
                "AgentBridgeCore",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "ClaudeAFMBridge",
            dependencies: [
                "ClaudeAdapter",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .target(
            name: "RingoCore",
            dependencies: [
                "AgentBridgeCore",
                "AFMBackend",
                "BridgeHTTP",
                "ClaudeAdapter",
                "CodexAdapter",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "RingoCLI",
            dependencies: [
                "RingoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "AgentBridgeCoreTests",
            dependencies: ["AgentBridgeCore"]
        ),
        .testTarget(
            name: "AFMBackendTests",
            dependencies: ["AFMBackend", "AgentBridgeCore"]
        ),
        .testTarget(
            name: "CodexAdapterTests",
            dependencies: [
                "CodexAdapter",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "ClaudeAdapterTests",
            dependencies: [
                "ClaudeAdapter",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        .testTarget(
            name: "RingoCoreTests",
            dependencies: [
                "RingoCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
    ]
)
