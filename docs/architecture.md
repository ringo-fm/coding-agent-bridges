# Architecture

## Layers

### AgentBridgeCore

Protocol-neutral domain model. It must not import Apple Foundation Models, Hummingbird, or OpenAI/Anthropic wire types.

### AFMBackend

Owns Apple Foundation Models integration, session creation, token counting, generation, streaming, cancellation, and tool-call strategies.

### BridgeHTTP

Provides shared HTTP infrastructure such as server configuration, authentication, health checks, JSON encoding, and low-level SSE framing. Protocol event payloads remain in adapters.

### CodexAdapter

Maps OpenAI Responses API and Codex-specific compatibility behavior to and from the protocol-neutral model.

### ClaudeAdapter

Maps Anthropic Messages API and Claude Code-specific compatibility behavior to and from the protocol-neutral model.

### Executables

`CodexAFMBridge` and `ClaudeAFMBridge` assemble configuration and dependencies. Business logic must remain in library targets.

## Dependency rules

```text
CodexAFMBridge  -> CodexAdapter  --+
                                  +-> AgentBridgeCore
ClaudeAFMBridge -> ClaudeAdapter -+-> AFMBackend
                                  +-> BridgeHTTP
```

- Adapters do not depend on one another.
- `AFMBackend` does not expose Foundation Models types across its public boundary.
- Tool execution remains in the coding agent, not in this bridge.
- Context planning is shared and token-budget-aware.

## Migration strategy

Import the latest source snapshots from `ringo-fm/codex-bridge` and `ringo-fm/claude-bridge` incrementally. Preserve behavior first through tests, then extract shared implementation behind the target boundaries.

The original repositories remain the historical record unless a simple local `git subtree` migration is performed before substantial development continues here.
