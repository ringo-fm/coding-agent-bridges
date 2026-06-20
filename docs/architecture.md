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

`RingoCore` composes both adapters into one Hummingbird application. The gateway
shares a `FoundationModelsBackend`, context ledger, authentication policy, and
telemetry actor while adapters continue to own their wire formats and tool-call
strategies.

## Dependency rules

```text
CodexAFMBridge  -> CodexAdapter  --+
                                  +-> AgentBridgeCore
ClaudeAFMBridge -> ClaudeAdapter -+-> AFMBackend
                                  +-> BridgeHTTP
RingoCLI -> RingoCore -> CodexAdapter + ClaudeAdapter
```

- Adapters do not depend on one another.
- `AFMBackend` does not expose Foundation Models types across its public boundary.
- Tool execution remains in the coding agent, not in this bridge.
- Context planning is shared and token-budget-aware.

## Migration strategy

Import the latest source snapshots from `ringo-fm/codex-bridge` and `ringo-fm/claude-bridge` incrementally. Preserve behavior first through tests, then extract shared implementation behind the target boundaries.

The snapshot strategy is final. The monorepo already contained its package and
architecture history before source migration began, so combining histories now
would add risk without improving traceability. The standalone repositories remain
the permanent record for pre-migration commits.

The original repositories remain the historical record and will be archived only
after parity and live end-to-end validation are complete.

## Context storage

Context handling has three modes selected by `AFM_BRIDGE_CONTEXT_MODE`:

- `off`: stateless compatibility behavior
- `memory`: process-local context ledger and retrieval (default)
- `persistent`: SQLite WAL storage with FTS5 retrieval

Persistent storage is opt-in. Its default location is
`~/Library/Application Support/coding-agent-bridges/context.sqlite3`; startup fails
instead of silently downgrading when an explicitly requested database cannot be
opened or migrated.

The gateway mounts OpenAI-compatible routes at both `/v1` and `/openai/v1`, and
Anthropic-compatible routes under `/anthropic/v1`. Protocol-neutral dashboard,
session, and cache routes are owned by `RingoCore`; they consume only
`AgentBridgeCore` management models.
