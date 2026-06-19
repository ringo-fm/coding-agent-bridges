# Coding Agent Bridges

Monorepo for running coding agents against Apple Foundation Models (AFM).

This repository is the source of truth for the shared AFM runtime and protocol adapters used by:

- Codex through an OpenAI Responses API-compatible bridge
- Claude Code through an Anthropic Messages API-compatible bridge

## Architecture

The implementation is divided into protocol-independent core targets and protocol-specific adapters:

```text
CodexAFMBridge  -> CodexAdapter  --+
                                  +-> AgentBridgeCore
ClaudeAFMBridge -> ClaudeAdapter -+-> AFMBackend
                                  +-> BridgeHTTP
```

Planned Swift Package targets:

- `AgentBridgeCore`: protocol-neutral request, message, tool, result, diagnostics, and context-planning types
- `AFMBackend`: Apple Foundation Models runtime, token counting, streaming, and tool-call strategies
- `BridgeHTTP`: shared Hummingbird server, authentication, JSON, health, and SSE utilities
- `CodexAdapter`: OpenAI Responses API and Codex-specific compatibility behavior
- `ClaudeAdapter`: Anthropic Messages API and Claude Code-specific compatibility behavior
- `CodexAFMBridge`: `codex-afm-bridge` executable
- `ClaudeAFMBridge`: `claude-afm-bridge` executable

## Design rules

- The bridge translates model behavior but does not execute coding-agent tools.
- Tool execution, approval, and sandboxing remain the responsibility of Codex or Claude Code.
- OpenAI and Anthropic wire formats remain isolated in their respective adapters.
- Context reduction is centralized in a token-budget-aware context planner.
- `AgentBridgeCore` does not depend on Foundation Models, Hummingbird, OpenAI, or Anthropic types.

## Migration

The current implementations are being migrated from:

- `ringo-fm/codex-bridge`
- `ringo-fm/claude-bridge`

The latest source snapshots will be imported without combining Git histories unless a simple history-preserving migration path becomes available. The original repositories will remain available until feature parity and end-to-end validation are complete, then be archived with a pointer to this repository.

## Requirements

- macOS 26+
- Xcode 26+
- Swift 6.2+

## Status

Repository initialization and migration planning are in progress.
