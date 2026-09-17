# Feasibility Analysis: Mistral Vibe CLI Support

## Verdict

**Yes — adding Mistral Vibe is feasible and fits the existing driver
architecture with no structural refactoring.** The agent-agnostic contract
layer (the Phase A work from `docs/plans/codex-support.md`) is fully in place:
`AgentDriver` enum, `agentRegistry`, per-driver native-history rules, sandbox
requirement joining, capability flags, and the agnostic event protocol. A Vibe
driver is an additive change: one new enum member, one registry entry, one new
driver file, plus test/packaging plumbing.

The right integration point is **`vibe-acp`** (Vibe's built-in Agent Client
Protocol server), not the CLI's programmatic mode. Vibe is the third
major agent (after Copilot CLI and Gemini CLI) to ship a first-party ACP
adapter, and CyDo already holds a detailed ACP spec study at
`docs/research/acp/SPEC.md`.

---

## What Mistral Vibe provides (verified)

Source: <https://github.com/mistralai/mistral-vibe> (Apache 2.0, Python),
README and DeepWiki index as of 2026-09.

| Property | Value |
|---|---|
| Invocation | `vibe` (TUI), `vibe-acp` (ACP server), `vibe --prompt ...` (programmatic) |
| ACP transport | JSON-RPC 2.0, **line-delimited** over stdio, multi-session per process |
| ACP library | pins `agent-client-protocol == 0.11.0` (Python SDK) |
| Distribution | PyPI (`mistral-vibe`, provides `vibe` + `vibe-acp` entry points), static per-platform binaries on GitHub Releases (incl. `vibe-acp-<os>-<arch>-<ver>.tar.gz`), Nix flake |
| Sessions | persisted under `$VIBE_HOME` (default `~/.vibe`); `--resume SESSION_ID`, `--continue`; "Session logging must be enabled in your configuration for these features to work" |
| MCP | `config.toml` `[[mcp_servers]]` with stdio/http/streamable-http transports; tool names are `{server}_{tool}` (underscores); per-tool permission blocks |
| Permissions | ACP `session/request_permission` with `allow_once` / `allow_always` ("remainder of session") / `allow_always_permanent` / `reject_once`; built-in `auto-approve` agent profile; `--yolo` flag |
| LLM backends | Mistral API, **generic OpenAI-compatible endpoint** (`base_url` in config.toml), local llamacpp |
| Models | Devstral 2 family, `mistral-medium-3.5` (vision), selectable via `active_model` |
| Streaming | `agent_message_chunk` / `agent_thought_chunk` / `tool_call` / `tool_call_update` / `plan` ACP updates; reasoning deltas |
| Compaction | auto-compaction; surfaced over ACP as a synthetic `tool_call` ("Compacting conversation history...") — documented workaround pending an ACP RFD |
| Extras | AGENTS.md support, hooks (`pre_tool`/`post_tool`), skills, trust-folder system (`~/.vibe/trusted_folders.toml`), `VIBE_HOME` env override, update checker (disable with `enable_update_checks = false`) |

### Programmatic mode — evaluated and rejected for sessions

`vibe --prompt "..." --output streaming` emits one NDJSON line **per completed
history entry** (a `PublicHistoryEntry`), not per token or per tool event, and
the stream does not carry a session id ([issue #208](https://github.com/mistralai/mistral-vibe/issues/208)).
One process equals one prompt; there is no live steering, no in-flight
interrupt (kill only), and resume happens by spawning a new process. That
matches CyDo's **one-shot** shape (`completeOneShot` for title generation),
not the interactive streaming-session shape. Sessions must go through
`vibe-acp`.

---

## How it maps onto the driver architecture

### Transport precedent

`vibe-acp` is a long-lived JSON-RPC-over-stdio process serving multiple
sessions — architecturally identical to Codex `app-server` and the Copilot
SDK process. CyDo already has both halves of the machinery:

- `cydo.agent.process` (`FramingMode.ndjson` / `contentLength`) — ACP uses
  line-delimited framing, same as Codex app-server.
- `cydo.agent.sdk.SdkProcess` — the Copilot driver's shared JSON-RPC
  process router (`session.event` notifications, `permission.request`,
  `tool.call` server requests, ready-state gating, session registry). An ACP
  variant needs the same shape with ACP method names; the `ae.net.jsonrpc`
  codec already used there handles JSON-RPC 2.0.

Per-session process model: spawn **one `vibe-acp` per task session** (as the
Copilot driver does per session) with a per-task `VIBE_HOME`. This yields
per-task MCP config, per-task history, and per-task trust isolation without
needing the Codex-style workspace process pool.

### Translation layer

ACP `session/update` variants map onto the agnostic protocol the same way the
Copilot driver translates SDK events (`copilot.d: translateLiveEvent` /
`translateHistoryLine`):

| vibe-acp event | Agnostic event |
|---|---|
| `session/new` response | `session/init` (synthetic; `agent: "vibe"`) |
| `agent_message_chunk` | `item/started` (text) + `item/delta` (`text_delta`) |
| `agent_thought_chunk` | `item/started` (thinking) + `item/delta` (`thinking_delta`) |
| `tool_call` | `item/started` (`tool_use`, name/input) |
| `tool_call_update` (completed) | `item/completed` + `item/result` |
| `tool_call_update` with `diff` content | `item/result` (diff payload → existing diff rendering path) |
| compaction synthetic tool_call start/end | `session/compacted` (consume the tool_call pair) |
| `user_message_chunk` (load replay) | `item/started` (`user_message`) |
| `session/prompt` response (`stopReason`) | `turn/stop` + `turn/result` |
| `session/request_permission` | auto-approve (respond `selected: allow_once`) — same policy as the Copilot driver |
| `session_info_update` (title) | pass-through or ignore initially |
| `plan` | ignore initially (CyDo has its own task tree) |

The `session/prompt` request/response pair gives an exact turn boundary — the
submission-receipt semantics (`AgentSubmissionReceipt.appServerAccepted`) fall
out naturally, as they do for Codex/Copilot.

---

## Changes required (inventory)

### Backend core

1. **`source/cydo/runtime/config/package.d`** — add `vibe` to
   `enum AgentDriver`; extend `driverSupportsEffort` (`final switch`).
   Vibe exposes a `thinking` config option (`disabled`/`medium`/`high`) over
   ACP config options, so `true` is defensible once the set-config-option
   path is wired; start with `false` if unset initially.
2. **`source/cydo/agent/drivers/registry.d`** — add
   `AgentRegistration("vibe", "Mistral Vibe", ...)`. Everything downstream
   (`resolveConfig` synthesis, `to!AgentDriver(name)` inference from config
   keys) is registry-driven and needs no further edits.
3. **`source/cydo/workflow/sessions/task_runner.d`** — extend the
   `final switch (ta.driver)` install-hint block
   (`uv tool install mistral-vibe` / brew / GitHub release).
4. **`source/cydo/runtime/launch/environment.d`** — add the
   `NativeHistoryRule(AgentDriver.vibe, "VIBE_HOME", ".vibe", null)` case to
   the unittest's rules list.
5. **New `source/cydo/agent/drivers/vibe.d`** — `VibeAgent` + `VibeSession`.
   Estimated scope comparable to (likely smaller than) `copilot.d`, which is
   the closest existing template.

### Driver responsibilities (new file)

- `configureSandbox`: mount the vibe executable + CyDo binary; pass through
  `MISTRAL_API_KEY`, `VIBE_HOME`, `HTTPS_PROXY`; ensure `VIBE_HOME` resolves
  to the per-task profile dir.
- `createSession`: generate MCP config into `$VIBE_HOME/config.toml`
  (`[[mcp_servers]] name="cydo"`, stdio, `command = <cydo bin>`,
  `args = ["mcp-server"]`, `env = { CYDO_TID, CYDO_SOCKET, ... }` — the same
  env contract `generateCopilotMcpConfig` uses), pre-seed
  `trusted_folders.toml` for the work dir, write `enable_update_checks =
  false`, then spawn `vibe-acp` and run the ACP handshake
  (`initialize` → `session/new` with the task cwd).
- `sendMessage`: `session/prompt`; fulfill on the request response.
- `interrupt` / `sigint` / `stop`: `session/cancel` notification; stop =
  cancel + shutdown (mirrors `SdkProcess.shutdown` semantics, including the
  orphaned-child pipe-drain handling Copilot needed).
- `resolveModelSpec`: `small` → `devstral-2-small`-class, `medium` →
  `devstral-2`, `large` → `mistral-medium-3.5`-class (exact ids to pin at
  implementation time); config `model_aliases` override as usual.
- Capability flags: `needsBash = true`, `supportsFileRevert = false` (no
  rewind equivalent), `supportsDeveloperPrompt = false` initially — Vibe has
  system-prompt *replacement* via files, and ACP-mode prompt injection is not
  documented, so fall back to CyDo's prepend-to-user-input path (already
  supported) until a `session/new` extension is verified.
- History API (`historyPath`, `enumerateAllSessions`, `readSessionMeta`,
  `translateHistoryLine`, fork/undo primitives): return
  not-supported/nulls initially, exactly as the Copilot driver does where the
  SDK shape doesn't line up; see Open Questions.

### Frontend

- `web/src/types.ts`: driver-name comment (cosmetic).
- `web/src/components/ToolCall.tsx`: Vibe's MCP tools arrive as
  `cydo_<Tool>`; the driver translation strips the prefix and sets
  `tool_server = "cydo"`, `tool_source = "mcp"` (the established pattern),
  so only genuinely Vibe-native tools (`view`-equivalents, `todo`, …) need
  optional driver-scoped renderers. None are required for a first cut.
- No reducer/schema changes: the frontend consumes the agnostic protocol.

### Testing & packaging (`flake.nix`, `tests/`)

- Package Vibe as a fixed-output derivation like `copilot-cli`
  (`flake.nix:154-187`): prefer the static `vibe-acp` GitHub-release tarball
  (no Python runtime needed), or `uv tool install mistral-vibe` pinned.
- Mock backend: **no MITM proxy needed**. Vibe's generic backend takes a
  `base_url` in `config.toml` — point the test `VIBE_HOME` config at the
  existing mock server (`http://127.0.0.1:9000/v1`) speaking the
  OpenAI-compatible surface, or add a thin Mistral-shape handler to
  `tests/mock-api/server.mjs`. Pattern matching (`patterns.mjs`) is shared
  and driver-agnostic. This satisfies the "real binary, mocked API" testing
  principle without a `copilot-proxy.mjs` equivalent.
- Playwright: add a `vibe` project to `projectConfig` (`flake.nix:897-902`),
  add `"vibe"` to `knownAgents` (`flake.nix:930`), and author a starter spec
  (`vibe-basic-flow.spec.ts`: message → response, tool call, cancel)
  mirroring `copilot-tool-turn-delimit.spec.ts`. The per-test tag matrix
  (`<agent>-only` / `no-<agent>`) prunes cells automatically.
- E2E config: extend `tests/e2e/agent-sandbox-env.yaml` with a `vibe` agent
  entry (`driver: vibe`, `VIBE_HOME` env override).

---

## Capability matrix (initial cut vs. existing drivers)

| Capability | claude | codex | copilot | vibe (initial) |
|---|---|---|---|---|
| Streaming sessions | ✓ | ✓ | ✓ | ✓ |
| Live steering (queue) | ✓ | ✓ (`turn/steer`) | ✓ (queue) | queue → next `session/prompt` |
| Interrupt | ✓ | ✓ | ✓ | ✓ (`session/cancel`) |
| Images | ✓ | ✗ | ✗ | ✗ initially |
| Effort knob | ✓ | ✓ | ✗ | ✗ initially (`thinking` later) |
| CyDo MCP tools | ✓ | ✓ | ✓ | ✓ (`session/new mcpServers`, spike-verified) |
| Native file revert | ✓ | ✗ | ✗ | ✗ |
| Session resume (cross-restart) | ✓ | ✓ | ✓ | **open** (needs `session/load` verification) |
| Session fork | ✓ | ✓ | ✗ | ✗ |
| Offline history replay | ✓ | ✓ | ✓ | ✗ initially |

---

## Spike results (2026-09-17, vibe 2.25.4) — all questions resolved

The spike ran against live `vibe-acp` (SDK client + vibe's built-in wire
logger). Full findings: `docs/research/vibe-acp-wire.md`. Summary:

1. **ACP dialect.** Protocol version 1, standard current-v1 shapes — matches
   `docs/research/acp/SPEC_v1.md` exactly. `loadSession: true` (top-level),
   `sessionCapabilities` = list/fork/close, image+embeddedContext prompts.
   RPC structs can be written directly from SPEC_v1.
2. **Resume semantics.** Cross-process `session/load` **works**: replay arrives
   as `user_message_chunk`/`agent_thought_chunk`/`agent_message_chunk`/tool
   pairs, ends with a synthetic `checkpoint:resume:*` completed tool call, and
   continuation prompts prove full context survival. Resume lands in v1.
3. **MCP delivery.** `session/new` `mcpServers` **works** (verified with a live
   stdio FastMCP server; tool surfaced as `spike_spike_ping` and executed).
   No `config.toml` MCP bootstrap needed. Note vibe advertises
   `mcpCapabilities` all-false yet loads stdio servers — do not gate on it.
4. **Session storage.** `$VIBE_HOME/logs/session/session_<ts>_<id8>/` with
   `meta.json` (session_id, cwd, title, stats, config) + `messages.jsonl`
   (one LLM message per line: role/content/reasoning/tool_calls).
   `translateHistoryLine`/`enumerateAllSessions` are implementable.
5. **Prompt steering.** AGENTS.md files apply in ACP sessions (confirmed via
   the assembled system prompt in session meta). No raw developer-prompt wire
   field exists, so CyDo keeps the prepend-to-user-input path;
   `supportsDeveloperPrompt` stays false.
6. **Headless behavior.** No trust or update prompts fired; trust state is
   reported via `session/new` `field_meta.workspace_trust` but is not
   blocking. Pre-seeding `trusted_folders.toml` stays recommended-only.
   Sandbox needs python3 visible (or use the static release tarball).
7. **Model ids.** Default catalog: `mistral-medium-3.5` (default),
   `devstral-small`, `local` (llamacpp). Thinking knob: `off/low/medium/
   high/max`. Read options from `session/new configOptions` rather than
   hardcoding.

New findings that shape the driver: permission `toolCall` carries only
`toolCallId` (correlate with prior notifications); tool display name lives in
`_meta.tool_name` (`{server}_{tool}` for MCP, `effect_kind` distinguishes
shell/tool); compaction = tool pair with `_meta.checkpoint_kind: "compaction"`
(don't match titles); turn usage is on the `session/prompt` response; prompt
response also returns `field_meta.show_feedback_prompt` occasionally (ignore);
sessions are in-process — no orphaned children to reap at shutdown.

| Capability | claude | codex | copilot | vibe (spike-confirmed) |
|---|---|---|---|---|
| Streaming sessions | ✓ | ✓ | ✓ | ✓ |
| Live steering (queue) | ✓ | ✓ (`turn/steer`) | ✓ (queue) | queue → next `session/prompt` |
| Interrupt | ✓ | ✓ | ✓ | ✓ (`session/cancel` → `stopReason: cancelled`, verified) |
| Images | ✓ | ✗ | ✗ | **✓ possible** (`promptCapabilities.image=true`) — deferred |
| Effort knob | ✓ | ✓ | ✗ | **✓ possible** (`thinking` config option) — later |
| CyDo MCP tools | ✓ | ✓ | ✓ | ✓ (`session/new mcpServers`, verified) |
| Native file revert | ✓ | ✗ | ✗ | ✗ |
| Session resume (cross-restart) | ✓ | ✓ | ✓ | **✓ (`session/load`, verified)** |
| Session fork | ✓ | ✓ | ✗ | **✓ advertised** (`sessionCapabilities.fork`) — untested |
| Offline history replay | ✓ | ✓ | ✓ | **✓ feasible** (JSONL + meta.json) |

## Suggested phasing

1. ~~**Spike**~~ — **done 2026-09-17**; findings in
   `docs/research/vibe-acp-wire.md`, matrix above filled in.
2. **Driver core**: enum + registry + `vibe.d` with new-session/prompt/stream/
   cancel, sandbox config, one-shot via `--prompt` for titles. Unit tests
   against a scripted stdio connection (the `TestCopilotConnection` pattern).
3. **MCP tool delivery** + e2e: Nix packaging, mock-backend wiring, a
   `vibe` Playwright project, one basic-flow spec. Gate: `nix flake check`.
4. **History & resume**: both confirmed feasible by the spike — `session/load`
   resume and `messages.jsonl`/`meta.json` storage parsing.
5. **Polish**: thinking/effort mapping via config options, Vibe-native tool
   renderers if any, doc updates (README agent table).

---

## Risks

- **Protocol drift**: Vibe moves fast (2.x series, weekly-ish releases) and
  pins its ACP SDK; expect to track occasional method-shape changes — the
  same maintenance burden Copilot's versioned SDK already imposes
  (`permissionDecisionForCopilotVersion` exists for exactly this).
- **Offline history**: if Vibe's on-disk session format proves unsuitable,
  Vibe tasks lose restart-recovery parity with the other drivers (UI still
  shows history from CyDo's own event log; only *native* resume/fork is
  affected). CyDo's persistence keeps this a degradation, not data loss.
- **Compaction-as-tool_call**: the synthetic compaction tool call must be
  consumed by the translator (not rendered as a task tool call) — easy to
  miss in tests; add a dedicated case.
- **Prompt-injection path**: until `supportsDeveloperPrompt` is settled, task
  system prompts ride along in user input for Vibe — functionally fine, cosmetically
  different from the other drivers.
