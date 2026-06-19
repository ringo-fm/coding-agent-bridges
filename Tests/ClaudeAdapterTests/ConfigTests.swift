import Logging
import Testing
@testable import ClaudeAdapter

@Suite struct ConfigTests {
    @Test func envHostAndPortAreUsedWhenCliOptionsAreAbsent() {
        let config = BridgeConfig.resolve(
            host: nil,
            port: nil,
            authToken: nil,
            logLevel: nil,
            debug: false,
            environment: [
                "AFM_BRIDGE_HOST": "0.0.0.0",
                "AFM_BRIDGE_PORT": "9001",
                "AFM_BRIDGE_API_KEY": "secret",
                "AFM_BRIDGE_LOG_LEVEL": "debug",
                "AFM_BRIDGE_DEBUG": "1",
            ]
        )

        #expect(config.host == "0.0.0.0")
        #expect(config.port == 9001)
        #expect(config.authToken == "secret")
        #expect(config.logLevel == Logger.Level.debug)
        #expect(config.debug == true)
    }

    @Test func cliHostAndPortOverrideEnvironment() {
        let config = BridgeConfig.resolve(
            host: "127.0.0.1",
            port: 7777,
            authToken: "cli-token",
            logLevel: "warning",
            debug: true,
            environment: [
                "AFM_BRIDGE_HOST": "0.0.0.0",
                "AFM_BRIDGE_PORT": "9001",
                "AFM_BRIDGE_API_KEY": "env-token",
                "AFM_BRIDGE_LOG_LEVEL": "debug",
            ]
        )

        #expect(config.host == "127.0.0.1")
        #expect(config.port == 7777)
        #expect(config.authToken == "cli-token")
        #expect(config.logLevel == Logger.Level.warning)
        #expect(config.debug == true)
    }

    @Test func invalidEnvPortFallsBackToDefault() {
        let config = BridgeConfig.resolve(
            host: nil,
            port: nil,
            authToken: nil,
            logLevel: nil,
            debug: false,
            environment: ["AFM_BRIDGE_PORT": "not-a-number"]
        )

        #expect(config.port == 8766)
    }
}

