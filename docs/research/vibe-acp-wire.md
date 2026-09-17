# vibe-acp Wire Findings (Spike Results)

Live wire capture of `vibe-acp` v2.25.4 (2026-09-17), answering the spike
questions S1–S8 from `docs/plans/vibe-support-implementation.md`. Capture
method: the ACP Python SDK's own client (`acp.spawn_agent_process`) driving a
real `vibe-acp` process, plus vibe's built-in wire logger
(`VIBE_ACP_LOGGING_ENABLED=1` → `~/.vibe/logs/acp/messages.jsonl`). No shim
needed — vibe ships its own message observer.

**Test environment:** mistral-vibe 2.25.4, ACP Python SDK **0.12.1** in the
runtime venv (vibe's `pyproject.toml` pins `==0.11.0`; 0.12.1 is wire-compatible
— same v1 protocol, added elicitation surface). Real Mistral API backend.

---

## S1 — `initialize` result

```json
{
  "protocolVersion": 1,
  "agentCapabilities": {
    "loadSession": true,
    "promptCapabilities": {"image": true, "audio": false, "embeddedContext": true},
    "mcpCapabilities": {"http": false, "sse": false, "acp": false},
    "sessionCapabilities": {"list": {}, "fork": {}, "close": {}}
  },
  "authMethods": [
    {"id": "browser-auth", "name": "Sign in through Mistral AI Studio",
     "description": "Sign into Mistral Vibe through your Mistral AI Studio account."}
  ],
  "agentInfo": {"name": "@mistralai/mistral-vibe", "title": "Mistral Vibe", "version": "2.25.4"}
}
```

Key points:

- **Protocol version 1**, standard shapes — matches `docs/research/acp/SPEC_v1.md`.
  No 0.7.x-era dialect; the earlier plan assumption is obsolete.
- `loadSession: true` is the **top-level** flag (drives `session/load`), not
  `sessionCapabilities.resume` (which stays absent — v1 inconsistency, as
  documented in SPEC_v1).
- `sessionCapabilities`: `list`, `fork`, `close` advertised; `delete` and
  `resume` are not.
- `mcpCapabilities` all false — yet `session/new` MCP works (see S3): vibe
  never declares the capability but does load stdio servers. Driver must not
  gate on `mcpCapabilities`.
- With a valid API key in the environment, `authMethods` still lists
  `browser-auth`; the driver can ignore auth entirely (env key path works —
  `MISTRAL_API_KEY` was picked up without calling `authenticate`).
- If the client advertises `field_meta["terminal-auth"]`, a `TerminalAuthMethod`
  (`id: "vibe-setup"`) is added; CyDo won't need it.

## S2 — `session/update` variant names (dispatch table)

Exactly the stable v1 set, no surprises:

| `sessionUpdate` | Observed | Notes |
|:----------------|:---------|:------|
| `user_message_chunk` | yes | replay + prompts echo |
| `agent_message_chunk` | yes | **includes `messageId` (UUID)** even though optional in v1 schema |
| `agent_thought_chunk` | yes | same shape; reasoning deltas |
| `tool_call` | yes | see below |
| `tool_call_update` | yes | see below |
| `plan` | yes | via `todo` tool (not exercised in capture; source-confirmed) |
| `available_commands_update` | yes | slash commands with `input.hint` |
| `session_info_update` | yes | auto-title = first prompt text |
| `usage_update` | yes | see below |
| `current_mode_update` | expected | source-confirmed (`set_session_mode` supported) |
| `config_option_update` | expected | source-confirmed |

Not emitted by vibe: `notice`, `compaction_update`, `compaction_summary_chunk`,
`plan_update`, `plan_removed` (unstable variants absent in 0.12.1-era SDK).

### `tool_call` / `tool_call_update` shapes

```json
// tool_call (start)
{"toolCallId": "UtzTH8sOo", "title": "bash", "kind": "execute",
 "status": "in_progress",
 "_meta": {"tool_name": "bash", "effect_kind": "shell"}}

// tool_call_update (progress — title gains args, rawInput appears)
{"toolCallId": "UtzTH8sOo", "kind": "execute", "status": "in_progress",
 "title": "bash: echo vibe-spike-ok",
 "rawInput": {"command": "echo vibe-spike-ok"},
 "_meta": {"tool_name": "bash", "effect_kind": "shell"}}

// tool_call_update (completed — content + rawOutput)
{"toolCallId": "UtzTH8sOo", "kind": "execute", "status": "completed",
 "content": [{"type": "content",
              "content": {"type": "text", "text": "vibe-spike-ok\n"}}],
 "rawOutput": {"stdout": "vibe-spike-ok\n", "stderr": "", "output": "",
               "truncated": false},
 "_meta": {"tool_name": "bash", "effect_kind": "shell"}}
```

**`_meta.tool_name` is the reliable tool-name source** (not the title). MCP
tools arrive as `{server}_{tool}` with `effect_kind: "tool"` — e.g.
`_meta.tool_name = "spike_spike_ping"` for server `spike` + tool `spike_ping`.
The `_` splitting ambiguity is real (server names may contain `_`); CyDo's own
server should use a prefix that can't appear in tool names, or the driver
matches `tool_name` against a known `cydo_*` list. `effect_kind` distinguishes
`shell` / `tool` / (others unobserved).

### `usage_update`

```json
{"used": 0, "size": 200000,
 "_meta": {"steps": 0, "promptTokens": 0, "completionTokens": 0,
           "cachedTokens": 0, "totalTokens": 0, "tokensPerSecond": 0.0,
           "lastTurnDuration": 0.0, "lastTurnTotalTokens": 0}}
```

`used`/`size` are the context-window numbers; the interesting per-turn token
counts ride in `_meta` (non-standard). The `session/prompt` **response** also
carries a standard `usage` object
(`total_tokens/input_tokens/output_tokens/thought_tokens/cached_read_tokens/cached_write_tokens`)
— the driver should take turn usage from the response, not `usage_update`.

### Permission requests

```json
{"toolCall": {"toolCallId": "2M1wWPiiD"},   // NOTE: id only, no title/kind!
 "options": [
  {"optionId": "allow_once",            "name": "Allow once",                          "kind": "allow_once"},
  {"optionId": "allow_always",          "name": "Allow for remainder of this session", "kind": "allow_always"},
  {"optionId": "allow_always_permanent","name": "Always allow",                        "kind": "allow_always"},
  {"optionId": "reject_once",           "name": "Deny",                                "kind": "reject_once"}]}
```

- `toolCall` contains **only `toolCallId`** — the client must correlate with
  the preceding `tool_call`/`tool_call_update` notifications for display.
- `allow_always_permanent` is a vibe-specific `optionId` but reuses standard
  `kind: "allow_always"`. Key decisions off `optionId`; `allow_once` is the
  right auto-approve choice for CyDo.
- With the user's stock config, **allowlisted commands never prompt**
  (`echo`, `cat`, `ls`, … are pre-allowlisted in the default `bash` allowlist).
  `ask_user_question` and `exit_plan_mode` are disabled by default in ACP
  sessions (config `disabled_tools`), so no elicitation is expected in the
  normal CyDo path.

## S3 — `session/new` `mcpServers`: **WORKS**

Verified end-to-end with a live FastMCP stdio server passed via
`session/new mcpServers`:

```json
{"name": "spike", "command": "/usr/bin/python3",
 "args": ["/tmp/vibe-acp-capture/mcp_server.py"], "env": []}
```

Result: tool registered as `spike_spike_ping` (`{server}_{tool}`), model called
it, permission gate fired, output came back via
`rawOutput.structured.result`. **No `config.toml` MCP bootstrap needed for
tool delivery** — `generateCopilotMcpConfig`-style file generation is not
required for the CyDo MCP contract. `config.toml` is still needed for backend
override (mock API) and telemetry/update suppression.

## S4 — Cross-process `session/load`: **WORKS**

Fresh `vibe-acp` process, `session/load` with the previous process's
`sessionId`:

1. `session/load` response: `{modes, configOptions}` (same shape as
   `session/new`).
2. Replay arrives **before** the response, as `session/update` notifications:
   `session_info_update`, then per history entry:
   `user_message_chunk` / `agent_thought_chunk` / `agent_message_chunk` /
   `tool_call` + `tool_call_update` (completed).
3. Replay ends with a synthetic completed `tool_call`:
   `toolCallId: "checkpoint:resume:<uuid>"`, `title: "Session resumed"`.
4. Continuation prompt proved full context survival (model quoted the earlier
   exchange exactly).
5. `stopReason: "cancelled"` from the interrupted first-process turn did **not**
   poison the resumed session.

Driver can implement cross-restart resume with the standard
`initialize → session/load` flow. Replay handling: treat
`user_message_chunk` as replay user items, chunks as history items, and
consume the `checkpoint:resume:*` tool call pair.

## S5 — On-disk session format: **parseable JSONL + meta.json**

```
~/.vibe/logs/session/
├── .session_index.json                      # index
├── active/<session-id>.lock                 # live-session locks
└── session_<YYYYMMDD>_<HHMMSS>_<first8>/    # one dir per session
    ├── meta.json
    └── messages.jsonl
```

- `meta.json`: rich snapshot — `session_id`, `parent_session_id`,
  `start_time`, `end_time`, `origin_directory` (= cwd → project matching),
  `title` (may be null → then from first user message), `stats`
  (tokens/cost/tool call counts), the full config used, `agent_profile`,
  and the final system prompt.
- `messages.jsonl`: **one LLM message per line** —
  `{"role": "user"|"assistant", "content", "injected", "message_id", ...}`,
  assistant lines also carry `reasoning_content`, `tool_calls`,
  `tool_result` fields when present.

`enumerateAllSessions` (scan `.session_index.json` / `session_*` dirs,
read `meta.json`) and `translateHistoryLine` (map LLM-message lines to agnostic
items) are both feasible. Fork/undo note: compaction creates
**new session dirs** with `parent_session_id`/`child_sessions` links (also
surfaced in `CompactEndEvent.old_session_id/new_session_id`).

## S6 — System prompt / AGENTS.md in ACP mode: **applies**

`meta.json` of the ACP-driven session contains the fully assembled system
prompt including the instruction-hierarchy section that explicitly names
**repo AGENTS.md files** and **the user's AGENTS.md** as sources (levels 3–4),
plus project context injection. ACP sessions use the same orchestrator as the
TUI. `supportsDeveloperPrompt` can be `true` in the sense that AGENTS.md-style
project instructions apply; there is still **no documented raw-ACP wire field**
to inject an arbitrary developer prompt with `session/new`, so CyDo's
prepend-to-user-input path remains the mechanism for the task system prompt
(as planned).

## S7 — Headless behavior: **no prompts observed**

The full capture ran non-interactive (pipes, no TTY) inside a plain
`spawn_agent_process` with `VIBE_ACP_LOGGING_ENABLED=1` and the stock
`~/.vibe/config.toml`:

- **Trust:** `session/new` returned
  `field_meta.workspace_trust = {"status": "untrusted"}` — informational only;
  the session executed normally (prompts, tools) without a trust prompt.
  Pre-seeding `trusted_folders.toml` (`trusted = ["/abs/path"]`) is still
  recommended for determinism but is not load-bearing.
- **Update checks:** `enable_update_checks = false` in `config.toml` is the
  suppression knob (no prompt appeared in any case).
- **No TTY assumptions** blocked the session; only the PTY helper
  (`sys.executable vibe/app_server/entrypoint.py --internal-posix-pty-helper`)
  is spawned per shell command. Under bwrap, mount the `vibe-acp` entry script,
  the vibe package, **and allow `sys.executable` (python3)** — or use the
  static `vibe-acp` GitHub-release tarball which bundles the interpreter.

## S8 — Model ids (current, from `session/new` `configOptions`)

| config option id | value | display |
|:-----------------|:------|:--------|
| `model` | `mistral-medium-3.5` (current default) | Mistral Medium 3.5 (`mistral-vibe-cli-latest`) |
| `model` | `local` | Devstral (local, llamacpp `devstral`) |
| `model` | `devstral-small` | devstral-small (`devstral-small-latest`) |
| `thinking` | `off` / `low` / `medium` / `high` / `max` (default `max`) | — |
| `mode` | `ask` / `plan` / `accept-edits` / `auto-approve` / `lean` | = session modes |

Mapping for `resolveModelSpec`: `small` → `devstral-small`, `medium` →
`mistral-medium-3.5`, `large` → `mistral-medium-3.5` (no larger tier exists in
the default catalog; pass through custom ids). The default catalog is
GrowthBook-tunable (`vibe_cli_default_routing_model` experiment), so read the
options from `session/new` rather than hardcoding where possible.

---

## Additional findings that shape the driver

1. **Process model:** `vibe-acp` is a single Python process; sessions are
   in-process (the "app server" runs inside it; `create_harness_server(
   transport_kind="in_process")`). No persistent child to reap except the
   short-lived PTY helper. The `SdkProcess.shutdown` orphan-drain dance is
   likely unnecessary; simple `closeStdin + terminate` should suffice (verify
   under bwrap).
2. **Session modes + config options:** `session/new` returns both `modes`
   (`ask` default) and `configOptions` (`mode`, `model`, `thinking`).
   `auto-approve` mode (`bypass_tool_permissions: true`) is available via
   `session/set_mode` — an alternative to per-request permission handling for
   headless tasks, but per-request auto-approve is more faithful to CyDo's
   permission UX.
3. **Compaction surface:** source-confirmed — compaction surfaces as a
   `tool_call`/`tool_call_update` pair with `kind: "think"`, status
   pending→completed, and **`_meta.checkpoint_kind: "compaction"`**
   (`field_meta` in the SDK). Detect via `_meta.checkpoint_kind`, not title
   matching ("Compacting conversation history" was the older TUI string).
   `checkpoint:resume:*` ids mark the resume marker (also consume).
4. **Auth:** with `MISTRAL_API_KEY` present, no `authenticate` call is needed.
   `authMethods` non-empty does not block session creation.
5. **`usage` on the prompt response** is stable per-turn usage;
   `usage_update._meta` carries vibe-specific counters (tokens/sec, step
   counts) — ignore for v1.
6. **Message ids:** `agent_message_chunk` includes `messageId` (UUID) — keep
   it as the streaming-item correlation key in the driver translation.

## Answers → plan deltas

| Spike item | Answer | Plan impact |
|:-----------|:-------|:------------|
| S1 | v1 standard, `loadSession=true`, list/fork/close caps | RPC structs = SPEC_v1 as-is |
| S2 | Stable v1 variants only; `_meta.tool_name` for names | Dispatch table final; drop 0.7.x concerns |
| S3 | `mcpServers` works | Skip `config.toml` MCP generation; keep config.toml for backend/telemetry only |
| S4 | Cross-process `session/load` works, replay = chunks + resume checkpoint | Step 8 (resume) → v1 scope |
| S5 | JSONL of LLM messages + meta.json with cwd/title | Step 9 (history) → feasible |
| S6 | AGENTS.md applies; no raw developer-prompt wire field | `supportsDeveloperPrompt` stays false; prepend path unchanged |
| S7 | No trust/update prompts; python3 needed under sandbox | Pre-seed trust optional; static tarball recommended |
| S8 | `devstral-small` / `mistral-medium-3.5`; thinking `off..max` | Pin as planned; thinking maps to effort knob later |

Capture artifacts (this machine, ephemeral): `/tmp/vibe-acp-capture/`
(`capture.py`, `capture2.py`, `capture3.py`, `mcp_server.py`,
`session-log.jsonl`). vibe's own log: `~/.vibe/logs/acp/messages.jsonl`.
