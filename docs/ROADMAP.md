# Coding Agent Bridges Roadmap

Implementation is in progress on `feat/implement-roadmap`. Source migration,
shared context/SQLite, structured compaction, non-streaming session reuse, and
staged Claude tool schemas are implemented; unchecked items remain acceptance
gates rather than claims about current behavior.

This roadmap consolidates the open issues across the three bridge repositories. The monorepo is the future source of truth; the standalone repositories remain authoritative until migration parity and end-to-end validation are complete.

## Source issues

- [`coding-agent-bridges#1`](https://github.com/ringo-fm/coding-agent-bridges/issues/1) — initialize the monorepo and migrate both bridges
- [`coding-agent-bridges#2`](https://github.com/ringo-fm/coding-agent-bridges/issues/2) — make the local Git-history decision and run macOS 26 validation
- [`coding-agent-bridges#4`](https://github.com/ringo-fm/coding-agent-bridges/issues/4) — add the `ringo` launcher
- [`coding-agent-bridges#6`](https://github.com/ringo-fm/coding-agent-bridges/issues/6) — unified multi-protocol gateway
- [`coding-agent-bridges#7`](https://github.com/ringo-fm/coding-agent-bridges/issues/7) — live operational dashboard
- [`coding-agent-bridges#8`](https://github.com/ringo-fm/coding-agent-bridges/issues/8) — session and context management
- [`coding-agent-bridges#9`](https://github.com/ringo-fm/coding-agent-bridges/issues/9) — cache controls and diagnostics
- [`codex-bridge#1`](https://github.com/ringo-fm/codex-bridge/issues/1) — add stateful context compaction for Codex
- [`codex-bridge#2`](https://github.com/ringo-fm/codex-bridge/issues/2) — migrate Codex and retire the standalone repository
- [`claude-bridge#1`](https://github.com/ringo-fm/claude-bridge/issues/1) — add local context memory and staged ingestion for Claude
- [`claude-bridge#2`](https://github.com/ringo-fm/claude-bridge/issues/2) — migrate Claude and retire the standalone repository

## Phase 0: Migration decision and package baseline

- [ ] Choose snapshot import or unsquashed `git subtree` import before substantial migration work.
- [ ] Record the decision in `docs/architecture.md` and `coding-agent-bridges#1`.
- [ ] Establish one root `Package.swift` with core, backend, HTTP, adapter, executable, and test targets.
- [ ] Validate `swift package resolve`, `swift build`, and `swift test` on macOS 26 / Swift 6.2.
- [ ] Confirm both skeleton executables start.

## Phase 1: Shared foundations

### AgentBridgeCore

- [ ] Define protocol-neutral generation, streaming, tool, and result types.
- [ ] Keep the module independent of Foundation Models, Hummingbird, and protocol wire types.

### AFMBackend

- [ ] Consolidate model availability, session creation, generation options, and token counting.
- [ ] Implement non-streaming generation, cumulative-to-delta streaming, cancellation, and normalized errors.
- [ ] Keep the backend independent of OpenAI and Anthropic models.

### BridgeHTTP

- [ ] Consolidate Hummingbird startup, authentication, health, logging, and debug configuration.
- [ ] Share low-level JSON and SSE framing while retaining protocol-specific event payloads in adapters.

## Phase 2: Protocol adapters and tool calls

### CodexAdapter

- [ ] Port OpenAI Responses API models, model metadata, compatibility profiles, and feature flags.
- [ ] Preserve response storage and Codex-specific SSE event ordering and completion semantics.
- [ ] Port native `FoundationModels.Tool` capture.

### ClaudeAdapter

- [ ] Port Anthropic Messages API models, compatibility profiles, and feature flags.
- [ ] Preserve `/v1/messages/count_tokens`, `tool_use`, and `tool_result` behavior.
- [ ] Port structured-output tool-call generation and invalid-call fallback behavior.

### Shared tool contracts

- [ ] Define a common `ToolCallStrategy` interface without forcing both adapters onto one AFM mechanism.
- [ ] Centralize tool-name and argument validation.
- [ ] Ensure the bridges return external tool calls to their coding agents and never execute them.

## Phase 3: Shared context planning and memory

- [ ] Replace fixed character truncation with prioritized, token-budget-aware context planning.
- [ ] Always preserve the current request, unresolved tool results, required tools, and recent turns.
- [ ] Add structured truncation diagnostics and retain bounded prompt construction as the final guard.
- [ ] Detect append-only continuations and safely reuse AFM sessions; branch or invalidate on divergence.
- [ ] Compact older history into structured capsules while retaining source-turn references.
- [ ] Support process-local memory and opt-in persistent SQLite storage; keep persistence disabled by default.
- [ ] Retrieve exact archived source blocks by file path, symbol, keyword, tool relation, error text, and recency.
- [ ] Cache summaries for unchanged instructions, files, and large tool outputs.
- [ ] Reconstruct context after session eviction or restart and serialize concurrent mutation of a session.

### Adapter-specific context work

- [ ] Codex: preserve and resolve `previous_response_id` response chains.
- [ ] Codex: preserve current and pending tool state through compaction.
- [ ] Claude: add normalized prefix hashing and conversation fingerprinting.
- [ ] Claude: implement two-stage tool ingestion—compact catalog selection followed by the selected full schema.

## Phase 4: Tests and parity validation

- [ ] Import existing unit tests and fixtures from both standalone repositories.
- [ ] Add contract tests for request/response mapping, event ordering, errors, and tool validation.
- [ ] Cover continuation, branching, invalidation, compaction, retrieval, storage modes, and staged schemas.
- [ ] Add opt-in live AFM tests for availability, generation, token counting, cancellation, and streaming.
- [ ] Run non-streaming and streaming `codex exec` end-to-end tests.
- [ ] Run non-streaming and streaming `claude -p` end-to-end tests.
- [ ] Verify both agents receive tool calls and the bridge never executes those calls.

## Phase 5: Cutover and retirement

- [ ] Confirm all existing Codex and Claude behavior is represented by monorepo tests.
- [ ] Confirm both root-package executables build and both end-to-end smoke tests pass.
- [ ] Update standalone READMEs with a migration notice and the final monorepo release, tag, or commit.
- [ ] Close or transfer remaining actionable standalone issues.
- [ ] Confirm no consumers depend on unreleased standalone changes.
- [ ] Archive `ringo-fm/codex-bridge` and `ringo-fm/claude-bridge` through GitHub settings.

Do not archive either standalone repository before feature parity and end-to-end validation are confirmed.

## Product surfaces

- [x] Add `ringo claude`, `ringo codex`, `ringo run`, `ringo serve`, and `ringo doctor`.
- [x] Serve OpenAI and Anthropic protocol surfaces from one gateway process.
- [x] Share AFM backend, context ledger, auth policy, telemetry, and lifecycle.
- [x] Add a redacted live dashboard and structured runtime state endpoint.
- [x] Add session list, inspect, resume-bundle, export, delete, and prune APIs/CLI.
- [x] Add cache stats, search, inspect, prune, and clear APIs/CLI.
- [x] Require authorization for mutations and content-bearing responses.

## Non-goals

- Exposing one universal coding-agent wire protocol.
- Executing coding-agent tools inside a bridge.
- Combining this project with `ringo-fm/ringo-fm-bridge`.
- Rewriting history solely to make the monorepo appear older than it is.
