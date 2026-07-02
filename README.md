# Coding Agent Bridges

Monorepo for running coding agents against Apple Foundation Models (AFM).

This repository is the source of truth for the shared AFM runtime and protocol adapters used by:

- Codex through an OpenAI Responses API-compatible bridge
- Claude Code through an Anthropic Messages API-compatible bridge

## Quick start

The `ringo` launcher starts the required local bridge, waits for it to become
healthy, configures the selected coding agent for the local model, and cleans up
the bridge when the agent exits:

```bash
swift run ringo doctor
swift run ringo claude
swift run ringo codex
```

Pass agent arguments after `--`:

```bash
swift run ringo claude -- --dangerously-skip-permissions
swift run ringo codex -- exec "summarize this repository"

# Equivalent explicit form:
swift run ringo run claude -- --print "explain Package.swift"
```

Launcher commands select an available localhost port automatically, inherit the
terminal's standard input and output, forward interrupts, and return the child
agent's exit status.

### Daily Codex use

Build and install the launcher on this Mac:

```bash
swift build -c release --product ringo
install -m 755 .build/release/ringo "$HOME/.local/bin/ringo"
ringo doctor
```

`ringo codex` preserves the normal Codex home, including repository guidance,
skills, plugins, and MCP configuration. The bridge stages the tools relevant to
each request, disables hosted web search and personality instructions, reports
the context window detected from AFM at runtime, and uses persistent local
context by default:

```bash
ringo codex
ringo codex -- exec --sandbox read-only "inspect Package.swift"
ringo codex --context-mode memory
ringo codex --context-mode off
ringo codex --isolated-config
```

Non-interactive `ringo codex -- exec ...` runs in concise mode by default and
prints only the final agent response. Add `--verbose` before `--` to show Codex
events and gateway diagnostics:

```bash
ringo codex --verbose -- exec --sandbox read-only "inspect Package.swift"
```

`--inherit-user-config` remains as a compatibility alias for the default.
Use `--isolated-config` when an AFM-specific Codex home without user plugins or
MCP configuration is required.

The optional isolated Codex state and shared bridge context are stored under:

```text
~/Library/Application Support/coding-agent-bridges/codex-home
~/Library/Application Support/coding-agent-bridges/context.sqlite3
```

Remove those paths to clear AFM Codex sessions and bridge history. Stop any
running `ringo` process before deleting the SQLite database and its `-wal` and
`-shm` companions.

## Unified gateway

Use `serve` for editors, debugging, or integrations that are not launched as a
child process. One process mounts both protocol surfaces, the dashboard, and
the context management API on port 8765 by default.

```bash
swift run ringo serve
swift run ringo serve --port 9000
```

The important endpoints are:

```text
OpenAI Responses:  http://127.0.0.1:8765/openai/v1/responses
Anthropic Messages: http://127.0.0.1:8765/anthropic/v1/messages
Dashboard:          http://127.0.0.1:8765/dashboard
Health:             http://127.0.0.1:8765/health
```

Once healthy, `serve` prints the environment and Codex provider configuration.
The lower-level standalone executables remain available:

```bash
AFM_BRIDGE_API_KEY=dev swift run codex-afm-bridge
swift run claude-afm-bridge --auth-token dev
```

## Architecture

The implementation is divided into protocol-independent core targets and protocol-specific adapters:

```text
CodexAFMBridge  -> CodexAdapter  --+
                                  +-> AgentBridgeCore
ClaudeAFMBridge -> ClaudeAdapter -+-> AFMBackend
                                  +-> BridgeHTTP
RingoCLI         -> RingoCore ----+-> unified gateway / CodexAdapter / ClaudeAdapter
```

Swift Package targets:

- `AgentBridgeCore`: protocol-neutral request, message, tool, result, diagnostics, and context-planning types
- `AFMBackend`: Apple Foundation Models runtime, token counting, streaming, and tool-call strategies
- `BridgeHTTP`: shared Hummingbird server, authentication, JSON, health, and SSE utilities
- `CodexAdapter`: OpenAI Responses API and Codex-specific compatibility behavior
- `ClaudeAdapter`: Anthropic Messages API and Claude Code-specific compatibility behavior
- `RingoCore`: launcher configuration, process lifecycle, readiness, and diagnostics
- `RingoCLI`: primary `ringo` command-line interface
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

The latest source snapshots are imported without combining Git histories. The original repositories remain available until feature parity and end-to-end validation are complete, then will be archived with a pointer to this repository.

## Context memory

The bridges use a shared token-budget planner and local context ledger. Process-local
memory is enabled by default; persistent transcript and retrieval storage must be
enabled explicitly:

```bash
export AFM_BRIDGE_CONTEXT_MODE=persistent
# Optional overrides:
export AFM_BRIDGE_CONTEXT_PATH="$HOME/Library/Application Support/coding-agent-bridges/context.sqlite3"
export AFM_BRIDGE_CONTEXT_RETENTION_DAYS=30
```

Set `AFM_BRIDGE_CONTEXT_MODE=off` for stateless compatibility behavior. Persistent
mode uses SQLite WAL and FTS5; the bridge fails startup if the requested database
cannot be opened or migrated.

## Dashboard and management

The dashboard displays runtime health, mounted protocols, request telemetry,
recent failure IDs, session summaries, and cache statistics. It never displays
prompts, completions, tool arguments, or authentication tokens.

The same data is available through `ringo`:

```bash
swift run ringo sessions list
swift run ringo sessions show <conversation-id>
swift run ringo sessions export <conversation-id>
swift run ringo sessions export <conversation-id> --include-content
swift run ringo sessions resume <conversation-id>
swift run ringo sessions delete <conversation-id>
swift run ringo sessions prune

swift run ringo cache stats
swift run ringo cache search "compiler error"
swift run ringo cache show <artifact-hash>
swift run ringo cache prune --days 30
swift run ringo cache clear
```

Redacted reads are available without credentials when the gateway is bound to
loopback. Mutations and `--include-content` require the configured bearer token;
all management access requires authentication when the server binds to a
non-loopback host.

## Requirements

- macOS 26+
- Xcode 26+
- Swift 6.2+
- Codex CLI for `ringo codex`
- Claude Code CLI for `ringo claude`

## Live Codex instruction-following E2E

The opt-in E2E test launches the real Codex CLI through `ringo`, uses Apple
Foundation Models to inspect a temporary repository, and verifies that Codex
follows its `AGENTS.md` while producing an exact requested artifact. It is not
part of `swift test` or the default GitHub Actions workflow because it requires
macOS 26, available AFM assets, and an installed Codex CLI.

```bash
CODEX_BIN=/Applications/Codex.app/Contents/Resources/codex \
  Tests/E2E/codex-instruction-following.sh
```

`CODEX_BIN` defaults to `codex` on `PATH`. The script rejects a CLI that cannot
run `--version`, enforces a 180-second timeout (override with
`E2E_TIMEOUT_SECONDS`), and preserves its temporary workspace with the Codex
log and Git diff when the test fails.

The equivalent Claude Code E2E uses the same deterministic repository task:

```bash
CLAUDE_BIN="$(command -v claude)" \
  Tests/E2E/claude-instruction-following.sh
```

## Status

The standalone Codex and Claude implementations and their unit/contract tests have
been migrated. Shared runtime, context planning, structured compaction, persistent
retrieval, session reuse, and staged Claude/Codex tool-schema ingestion are implemented.
The unified gateway, dashboard, session management, and artifact cache controls
are also implemented. Live agent validation and repository cutover remain in progress.
