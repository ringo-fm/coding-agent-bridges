import CodexAdapter
let config = try BridgeConfig.load()
try await runCodexBridge(config: config)
