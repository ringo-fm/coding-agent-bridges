import CodexAdapter
import AgentBridgeCore
import Logging

let config = try BridgeConfig.load()
let profile = CompatibilityProfile.loadFromEnv()

var logger = Logger(label: "codex-afm-bridge")
logger.logLevel = config.logLevel
logger.info("Compatibility profile: \(profile.name)")

let afm = AFMRuntime()
let availability = afm.availability()
if availability.isAvailable {
    logger.info("Apple Foundation Models available (\(SupportedModels.canonical)).")
} else if case .unavailable(let reason) = availability {
    logger.warning("Apple Foundation Models unavailable: \(reason.message)")
}

let services = BridgeServices(
    afm: afm,
    store: ResponseStore(),
    config: config,
    profile: profile,
    logger: logger,
    contextLedger: try ContextLedgerFactory.make(
        mode: config.contextMode,
        path: config.contextPath,
        retentionDays: config.contextRetentionDays
    )
)
try await BridgeServer(services: services).run()
