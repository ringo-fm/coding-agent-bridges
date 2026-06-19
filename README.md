# Coding Agent Bridges

Monorepo for running coding agents against Apple Foundation Models (AFM).

This repository is the source of truth for the shared AFM runtime and protocol adapters used by:

- Codex through an OpenAI Responses API-compatible bridge
- Claude Code through an Anthropic Messages API-compatible bridge

## Quick start

Build all command-line tools:

```bash
swift build -c release
```

Add the release products to `PATH`:

```bash
export PATH="$PWD/.build/release:$PATH"
```

Check the local machine and installed tools:

```bash
ringo doctor
```

Run Codex through AFM:

```bash
ringo codex -- <codex-args>
```

Run Claude Code through AFM:

```bash
ringo claude -- <claude-args>
```

Long-form aliases are also supported:

```bash
ringo run codex -- <codex-args>
ringo run claude -- <claude-args>
```

Run only the bridge server:

```bash
ringo serve codex
ringo serve claude
```

## Runtime behavior

`ringo` is the end-to-end launcher. It starts the matching local AFM bridge, waits for the HTTP server to become reachable, injects the local provider environment variables, runs the requested coding-agent CLI, and then shuts down the bridge when the agent exits.

The generated flow is:

```text
ringo codex
  -> codex-afm-bridge
  -> OPENAI_BASE_URL=http://127.0.0.1:8765/v1
  -> codex <args>

ringo claude
  -> claude-afm-bridge
  -> ANTHROPIC_BASE_URL=http://127.0.0.1:8766
  -> claude <args>
```

`AFM_BRIDGE_API_KEY` is used when present. Otherwise `ringo run`, `ringo codex`, and `ringo claude` generate a per-run local token and pass it to both the bridge and the child CLI.

## Configuration

Common bridge configuration:

```bash
export AFM_BRIDGE_HOST=127.0.0.1
export AFM_BRIDGE_PORT=8765
export AFM_BRIDGE_API_KEY=local-dev-token
```

Bridge executable overrides:

```bash
export RINGO_CODEX_BRIDGE=/path/to/codex-afm-bridge
export RINGO_CLAUDE_BRIDGE=/path/to/claude-afm-bridge
```

Context memory:

```bash
export AFM_BRIDGE_CONTEXT_MODE=persistent
export AFM_BRIDGE_CONTEXT_PATH="$HOME/Library/Application Support/coding-agent-bridges/context.sqlite3"
export AFM_BRIDGE_CONTEXT_RETENTION_DAYS=30
```

Set `AFM_BRIDGE_CONTEXT_MODE=off` for stateless compatibility behavior. Persistent mode uses SQLite WAL and FTS5; the bridge fails startup if the requested database cannot be opened or migrated.

## Architecture

The implementation is divided into protocol-independent core targets and protocol-specific adapters:

```text
ringo ----------+-> CodexAFMBridge  -> CodexAdapter  --+
                |                                      +-> AgentBridgeCore
                +-> ClaudeAFMBridge -> ClaudeAdapter -+-> AFMBackend
                                                       +-> BridgeHTTP
```

Swift Package targets:

- `AgentBridgeCore`: protocol-neutral request, message, tool, result, diagnostics, and context-planning types
- `AFMBackend`: Apple Foundation Models runtime, token counting, streaming, and tool-call strategies
- `BridgeHTTP`: shared Hummingbird server, authentication, JSON, health, and SSE utilities
- `CodexAdapter`: OpenAI Responses API and Codex-specific compatibility behavior
- `ClaudeAdapter`: Anthropic Messages API and Claude Code-specific compatibility behavior
- `CodexAFMBridge`: `codex-afm-bridge` executable
- `ClaudeAFMBridge`: `claude-afm-bridge` executable
- `RingoCLI`: `ringo` executable launcher

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

The latest source snapshots are imported without combining Git histories. The original repositories remain available until feature parity and end-to-end validation are complete, then will be archived with a pointer to this repository.

## Requirements

- macOS 26+
- Xcode 26+
- Swift 6.2+
- Codex CLI for `ringo codex`
- Claude Code CLI for `ringo claude`

## Status

The standalone Codex and Claude implementations and their unit/contract tests have been migrated. Shared runtime, context planning, structured compaction, persistent retrieval, session reuse, staged Claude tool-schema ingestion, and the end-to-end `ringo` launcher are implemented.

Live agent validation and repository cutover remain in progress.
