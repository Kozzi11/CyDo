# Agent Client Protocol (ACP) — Protocol v2 Specification (Draft)

Reference for ACP protocol version `2`, based on the `main` branch of
[agentclientprotocol/agent-client-protocol](https://github.com/agentclientprotocol/agent-client-protocol)
and the v2 JSON Schema artifacts (`schema/v2/`).

**Protocol version:** `2` (integer, negotiated during `initialize`)
**Status:** ⚠️ **DRAFT / UNSTABLE** — v2 is under active development on `main`.
**Schema artifact:** `schema-v2.0.0-alpha.3` (2026-08-20) — `schema/v2/schema.json` + `schema/v2/schema.unstable.json`
**Rust runtime crate:** `agent-client-protocol` 1.6.0 (2026-07-21)
**Transport:** JSON-RPC 2.0 over NDJSON on stdio (default) or TCP
**License:** Apache 2.0

> **Everything in this document is subject to change.** v2 artifacts are
> published as `2.0.0-alpha.*` releases. An implementation targeting v2 today
> must expect breaking changes before it stabilizes. See
> [SPEC_v1.md](./SPEC_v1.md) for the stable protocol.

ACP is a bidirectional JSON-RPC 2.0 protocol between **Agents** (AI-powered
code assistants) and **Clients** (editors, IDEs, orchestrators). v2 is a
redesign of the v1 wire protocol focused on:

- **Session-centric lifecycle** — a single `session/update` stream carrying
  entity upserts (`agent_message`, `tool_call_update`, `terminal_update`,
  `plan_update`) instead of turn-scoped one-way events; a `state_update`
  variant replaces turn boundaries (`session/prompt` no longer signals
  completion).
- **Future-proof enums** — every enum accepts custom `_`-prefixed values;
  unknown non-`_` values are reserved for future ACP variants and must be
  preserved by receivers.
- **Removed client surfaces** — no more client-hosted `fs/*` or `terminal/*`
  methods; agents own terminals and stream output as session updates.
- **Simplified session setup** — no `modes`, `mcpServers` optional, one
  `session/resume` method with a `replayFrom` cursor.

```
Client ──stdin──▶ Agent    (client requests/notifications)
Client ◀──stdout── Agent   (agent responses/requests/notifications)
```

**Stability model:** same as v1 — unstable features live in
`schema.unstable.json` and may change or be removed at any time.

---

## Method Surface (schema v2 meta.json)

### Agent methods (client → agent)

| Method | Status | Capability gate |
|:-------|:-------|:----------------|
| `initialize` | stable | required, always first |
| `auth/login` | stable | only if `authMethods` non-empty (replaces v1 `authenticate`) |
| `auth/logout` | stable | only if `authMethods` non-empty (required with login) |
| `session/new` | stable | required |
| `session/resume` | stable | baseline session capability — unifies v1 `session/load` + `session/resume` |
| `session/list` | stable | baseline session capability |
| `session/delete` | stable | `sessionCapabilities.delete` |
| `session/fork` | unstable | `sessionCapabilities.fork` |
| `session/close` | stable | baseline session capability |
| `session/prompt` | stable | required |
| `session/cancel` | stable | required (notification) |
| `session/set_config_option` | stable | `configOptions` returned in session response |
| `providers/list`, `providers/set`, `providers/disable` | unstable | `providers` |
| `nes/*` + `document/*` | unstable | `nes` |
| `mcp/message` | unstable | `session.mcp.acp` |

### Client methods (agent → client)

| Method | Status | Capability gate |
|:-------|:-------|:----------------|
| `session/update` | stable | required (notification) |
| `session/request_permission` | stable | required |
| `elicitation/create`, `elicitation/complete` | stable | `elicitation.form` / `elicitation.url` |

**Removed client surfaces:** v2 has **no** `fs/read_text_file`,
`fs/write_text_file`, or `terminal/*` client methods. File access and terminal
ownership move to the agent; terminal output reaches the client through
`terminal_update` / `terminal_output_chunk` session updates.

### Protocol-level notifications

| Method | Direction | Status |
|:-------|:----------|:-------|
| `$/cancel_request` | either | stable — cancels any in-flight request by `id` |

---

## Protocol Lifecycle

### Phase 1: Initialization

```
Client ──▶ initialize(protocolVersion, info, capabilities)
Client ◀── {protocolVersion, info, capabilities, authMethods?}
```

Both sides MUST send implementation `info` (name + version) — **required** in
v2, optional in v1.

### Phase 2: Authentication (optional)

If the initialize response contains a non-empty `authMethods` list, the agent
MUST support both `auth/login` and `auth/logout`; the client MUST NOT call
either when `authMethods` was omitted or empty.

- `{type: "terminal", ...}` — client runs the agent interactively in a
  terminal; not passed to `auth/login`.
- `{type: "agent", methodId, name, ...}` — agent handles auth via `auth/login`
  with that `methodId`. Note the field is `methodId` in v2 (v1 used `id`).
- `{type: "<custom>", methodId, name, ...}` — future/custom method types.

### Phase 3: Session Setup

```
Client ──▶ session/new(cwd, mcpServers?, additionalDirectories?)
Client ◀── {sessionId, configOptions?}
```

`mcpServers` is **optional** (empty default) and only stdio/http/acp transports
exist (SSE removed).

### Phase 4: Prompt Lifecycle

The big change: `session/prompt` **acknowledges** the prompt; completion is
signaled by a `state_update` session update.

```
Client ──▶ session/prompt(sessionId, prompt)
Client ◀── {}                                     ← acknowledgment (empty result)
Agent  ──▶ session/update {sessionUpdate: "state_update", state: "running"}
Agent  ──▶ session/update {sessionUpdate: "agent_message_chunk", messageId, content}
Agent  ──▶ session/update {sessionUpdate: "tool_call_update", toolCallId, status, ...}
Agent  ──▶ session/request_permission(...)        ← if approval needed (has id)
Client ──▶ {outcome}                              ← permission response
Agent  ──▶ session/update {sessionUpdate: "state_update", state: "idle", stopReason, usage?}
```

Sessions are also long-lived: agents may emit `session/update` notifications at
any time while the session exists (not only during foreground work). When
`idle`, background activity can continue emitting updates without flipping the
state back to `running`.

### Phase 5: Shutdown

Close the transport; use `session/close` to free one session's resources.
Agents SHOULD treat `session/close` as cancel + resource cleanup.

---

## Client → Agent Methods

### `initialize`

```typescript
type InitializeRequest = {
  protocolVersion: number;          // latest version the client supports (2)
  info: { name: string; version: string; title?: string };   // REQUIRED
  capabilities: {
    auth?: { terminal?: boolean };
    elicitation?: { form?: {}; url?: {} };
    nes?: {};                       // unstable
    positionEncodings?: string[];   // unstable
  };
};

type InitializeResponse = {
  protocolVersion: number;
  info: { name: string; version: string; title?: string };   // REQUIRED
  capabilities: {
    session?: {                     // presence = baseline session support
      prompt?: { image?: boolean; audio?: boolean; embeddedContext?: boolean };
      mcp?: { stdio?: {}; http?: {}; acp?: {} };             // acp unstable
      delete?: {}; additionalDirectories?: {}; fork?: {};
    };
    auth?: { logout?: {} };         // extension caps; login/logout advertised via authMethods
    providers?: {};                 // unstable
    nes?: {};                       // unstable
    positionEncoding?: string;      // unstable
  };
  authMethods?: AuthMethod[];       // omitted/empty = no auth surface
};
```

Note: v2 nests all session, prompt, and MCP capabilities under
`capabilities.session`; v1 kept `loadSession`, `promptCapabilities`, and
`mcpCapabilities` at the top level.

---

### `auth/login` / `auth/logout`

```typescript
type LoginAuthRequest  = { methodId: string };   // replaces v1 `authenticate`
type LoginAuthResponse = {};

type LogoutAuthRequest  = {};                    // replaces v1 `logout`
type LogoutAuthResponse = {};
```

Grouped under the `auth/*` namespace. An agent advertising `authMethods` MUST
implement both; there is no separate capability flag for logout (unlike v1's
`auth.logout`).

---

### `session/new`

```typescript
type NewSessionRequest = {
  cwd: string;                          // absolute path
  mcpServers?: McpServer[];             // OPTIONAL in v2
  additionalDirectories?: string[];
};

type NewSessionResponse = {
  sessionId: string;
  configOptions?: SessionConfigOption[];
  // no `modes` — v2 removed session modes entirely
};
```

---

### `session/resume` (unified)

One method replaces v1's `session/load` + `session/resume`. Baseline session
capability — no separate flag.

```typescript
type ResumeSessionRequest = {
  sessionId: string;
  cwd: string;
  mcpServers?: McpServer[];
  additionalDirectories?: string[];
  replayFrom?:
    | { type: "start" }                 // replay the whole conversation
    | null;                             // or omit: resume without replay
};

type ResumeSessionResponse = { configOptions?: SessionConfigOption[] };
```

Replay cursors are **inclusive**. Replay history arrives as `user_message`,
`agent_message`, and `agent_thought` upserts (whole messages, not just chunks).

---

### `session/list` / `session/delete`

```typescript
type ListSessionsRequest  = { cwd?: string; cursor?: string };
type ListSessionsResponse = { sessions: SessionInfo[]; nextCursor?: string };

type SessionInfo = {
  sessionId: string;
  cwd: string;
  additionalDirectories?: string[];
  title?: string;
  updatedAt?: string;                 // RFC 3339
};
```

---

### `session/prompt`

```typescript
type PromptRequest = {
  sessionId: string;
  prompt: ContentBlock[];
};

type PromptResponse = {};              // acknowledgment ONLY — no stopReason!
```

**Key difference from v1:** the response no longer carries `stopReason`.
Completion is reported via the `state_update` session update with
`state: "idle"` and an optional `stopReason` / `usage`.

Stop reasons (open set):

```typescript
type StopReason =
  | "end_turn" | "max_tokens" | "max_turn_requests" | "refusal" | "cancelled"
  | string;                            // custom `_`-prefixed values allowed
```

---

### `session/cancel`

Notification. Agents SHOULD report `state_update → idle` with
`stopReason: "cancelled"` when cancellation succeeds, and clients MUST answer
pending `session/request_permission` with `{outcome: "cancelled"}`.

---

### `session/set_config_option`

```typescript
type SetSessionConfigOptionRequest = {
  sessionId: string;
  configId: string;
  value:
    | { type: "id";      value: string }
    | { type: "boolean"; value: boolean }
    | { type: string;    value: unknown };   // custom `_`-prefixed types
};

type SetSessionConfigOptionResponse = { configOptions: SessionConfigOption[] };
```

Typed config values are **required** in v2 (`type` discriminator mandatory);
v1 allowed an untyped string shorthand.

---

## Agent → Client Methods

### `session/update`

Notification. Can arrive at any time while the session exists.

```typescript
type UpdateSessionNotification = {
  sessionId: string;
  update: SessionUpdate;              // discriminated by `sessionUpdate`
};
```

### `session/request_permission` (generalized)

```typescript
type RequestPermissionRequest = {
  sessionId: string;
  title: string;                      // REQUIRED, prompt-specific
  description?: string;               // why permission is needed
  subject?:
    | { type: "tool_call"; toolCall: ToolCallUpdate }
    | { type: "command";   command: string; cwd: string;
        toolCallId?: string; terminalId?: string }
    | { type: string; ... };          // custom subjects
  options: PermissionOption[];        // at least one
};

type PermissionOption = {
  optionId: string;
  name: string;
  kind: "allow_once" | "allow_always" | "reject_once" | "reject_always" | string;
};

type RequestPermissionOutcome =
  | { outcome: "selected"; optionId: string }
  | { outcome: "cancelled" };
```

v1's permission requests were always tool-call-scoped (`toolCall` field).
v2 makes the subject open-ended: tool calls, commands, or custom types.

---

## session/update Variants

All variants share the envelope `{sessionId, update: {sessionUpdate: "<name>", ...}}`.

| Variant | Status | Payload |
|:--------|:-------|:--------|
| `user_message_chunk` | stable | `ContentChunk` (**messageId required**) |
| `user_message` | stable | `UserMessage` upsert |
| `agent_message_chunk` | stable | `ContentChunk` (**messageId required**) |
| `agent_message` | stable | `AgentMessage` upsert |
| `agent_thought_chunk` | stable | `ContentChunk` (**messageId required**) |
| `agent_thought` | stable | `AgentThought` upsert |
| `state_update` | stable | `StateUpdate` (running / idle / requires_action) |
| `tool_call_content_chunk` | stable | `{toolCallId, content}` |
| `tool_call_update` | stable | `ToolCallUpdate` upsert |
| `terminal_update` | stable | `TerminalUpdate` upsert |
| `terminal_output_chunk` | stable | `{terminalId, data(base64)}` |
| `plan_update` | stable | `PlanUpdate` (ID-addressed) |
| `plan_removed` | unstable | `{planId}` |
| `available_commands_update` | stable | `{availableCommands}` |
| `config_option_update` | stable | `{configOptions}` |
| `session_info_update` | stable | `{title?, updatedAt?}` |
| `usage_update` | stable | `UsageUpdate` |
| `notice` | unstable | `{severity, title, description?}` |
| `compaction_update` | unstable | `CompactionUpdate` |
| `compaction_summary_chunk` | unstable | `{compactionId, content}` |
| *(custom)* | — | `_`-prefixed values: `{sessionUpdate: "_vendor/thing", ...}` |

Removed v1 variants: `tool_call` (merged into `tool_call_update`), `plan`
(full-replacement plan; replaced by ID-addressed `plan_update`),
`current_mode_update` (modes removed).

### Upsert semantics

Every entity update (messages, tool calls, terminals) follows the same
**upsert/patch** pattern:

- First update for an ID creates the entity ("fixes its timeline position").
- Later updates patch it in place: omitted field = unchanged; explicit `null`
  clears; concrete value replaces. Arrays replace wholesale (`[]` or `null`
  clears).
- Updates and chunks for the same entity apply in arrival order.

### Message chunks and whole messages

```typescript
type ContentChunk = {
  messageId: string;                  // REQUIRED in v2 (optional in v1)
  content: ContentBlock;
};

type AgentMessage = {
  messageId: string;                  // required
  content?: ContentBlock[] | null;    // patch semantics
};
// AgentThought and UserMessage have the same shape
```

Chunks with the same `messageId` append; an `agent_message` with content
replaces everything accumulated so far for that message.

### `state_update`

```typescript
type StateUpdate =
  | { state: "running" }
  | { state: "idle"; stopReason?: StopReason; usage?: Usage }
  | { state: "requires_action" }
  | { state: string };                // custom
```

- `running` — foreground work in progress.
- `idle` — agent ready for a new prompt; carries the v1-style end-of-turn
  information (`stopReason`, `usage`).
- `requires_action` — foreground work blocked on user action
  (e.g. pending permission request or elicitation).

### Tool calls

```typescript
type ToolCallUpdate = {              // upsert; id required, everything else patches
  toolCallId: string;
  title?: string; name?: string;     // name unstable
  kind?: ToolKind;
  status?: ToolStatus;
  content?: ToolCallContent[];       // replaces collection; [] or null clears
  locations?: ToolLocation[];
  rawInput?: object;
  rawOutput?: object;
};

type ToolKind = "read" | "edit" | "delete" | "move" | "search"
              | "execute" | "think" | "fetch" | "switch_mode" | "other" | string;

type ToolStatus = "pending" | "in_progress" | "completed" | "failed"
                | "cancelled"        // NEW in v2
                | string;

type ToolCallContent =
  | { type: "content";  content: ContentBlock }
  | { type: "diff";     changes: DiffChange[]; patch?: DiffPatch }
  | { type: "terminal"; terminalId: string }
  | { type: string };                 // custom `_`-prefixed content

type ToolCallContentChunk = { toolCallId: string; content: ToolCallContent };
```

A single `tool_call_update` both announces (status `pending`) and completes
(status `completed`/`failed`/`cancelled`) a tool call — v1's separate
`tool_call` variant is gone. Stream content incrementally with
`tool_call_content_chunk`.

### v2 Diff format

```typescript
type Diff = {
  changes: DiffChange[];              // REQUIRED, structured metadata
  patch?: {                           // optional renderable text
    format: "git_patch" | string;
    text: string;
  };
};

type DiffChange =
  | { operation: "add" | "delete" | "modify"; path: string;
      fileType?: string; mimeType?: string }
  | { operation: "move" | "copy"; oldPath: string; path: string; ... };
```

Clients MUST handle diffs with `patch` omitted. v1's flat
`{path, oldText?, newText}` diff is replaced by structured changes plus an
optional Git-format patch.

### Agent-owned terminals

v2 has no `terminal/*` client methods. Agents own terminals and stream their
state:

```typescript
type TerminalUpdate = {              // upsert
  terminalId: string;
  command?: string;
  cwd?: string;                       // absolute
  output?: { data: string } | null;   // base64 replacement snapshot
  exitStatus?: { exitCode?: number; signal?: string } | null;
};

type TerminalOutputChunk = { terminalId: string; data: string };  // base64 appends
```

Tool call content may reference terminals by id
(`{type: "terminal", terminalId}`) for display purposes.

### Plan

v2 adopts the ID-addressed `plan_update` as the only plan shape (v1's
full-replacement `plan` variant is gone):

```typescript
type PlanUpdate = {
  plan:
    | { type: "items"; entries: PlanEntry[]; planId: string }
    | { type: "file" | "markdown" | string; planId: string };   // file/markdown unstable
};

type PlanEntry = {
  content: string;
  priority: "high" | "medium" | "low";
  status: "pending" | "in_progress" | "completed"
        | "cancelled"                  // NEW in v2
        | string;
};
```

---

## Content Blocks

Same as v1 plus custom block types:

```typescript
type ContentBlock =
  | { type: "text" | "image" | "audio" | "resource_link" | "resource"; ... }
  | { type: string };                 // custom / future (preserve raw payload)
```

v2 `resource_link` additionally supports an `icons` array (with
`src`, `mimeType`, `sizes`, `theme: "light" | "dark"`).

All agents MUST support `text` and `resource_link` in prompts; image / audio /
resource require `session.prompt` capability flags.

---

## Session Config Options

```typescript
type SessionConfigOption = {
  id: string;
  name: string;
  description?: string;
  category?: "mode" | "model" | "model_config" | "thought_level" | string;
  type: "select" | "boolean";
  currentValue?: string | boolean;
  options?: SelectOption[] | SelectGroup[];
};
```

Identical shape to v1, but note `mode`/`thought_level` categories remain
defined while v2 itself has no session-modes API — the categories survive for
config option selection. Values set via `session/set_config_option` require the
`type` discriminator (`"id"` or `"boolean"`).

---

## MCP Servers

```typescript
type McpServer =
  | { type: "stdio"; name: string; command: string; args?: string[]; env?: EnvVariable[] }
  | { type: "http";  name: string; url: string; headers?: HttpHeader[] }
  | { type: "acp";   name: string; ... }        // unstable
  | { type: string };                           // custom transports

type McpCapabilities = {
  stdio?: {};                          // OPT-IN in v2 (was always-on in v1)
  http?: {};
  acp?: {};                            // unstable
};
```

**SSE transport removed.** Stdio changed from mandatory (v1: "All Agents MUST
support this transport", with required `args`/`env`) to capability-gated and
optional fields. Empty MCP arrays are optional in lifecycle requests.

---

## Elicitation (stable)

Same model as v1 (form + URL modes, accept/decline/cancel actions, session or
request scoping) — stabilized in schema 2.0.0-alpha.3. See
[SPEC_v1.md](./SPEC_v1.md#elicitation-stable-since-schema-1210) for the shape.

---

## Error Handling

Same JSON-RPC error codes as v1: `-32700`, `-32600`, `-32601`, `-32602`,
`-32603`, `-32800` (request cancelled), `-32000` (auth required), `-32002`
(resource not found).

---

## Extensibility

### Future-proof enums

v2's headline extensibility change: **every enum is an open set**.

- Values starting with `_` are free for implementation-specific use.
- Unknown non-`_` values are reserved for future ACP variants.
- Receivers that don't understand a value MUST preserve the raw payload when
  storing/replaying/proxying/forwarding, and otherwise ignore it or display it
  generically.

This applies to content blocks, tool kinds/statuses/content, stop reasons,
permission subjects, config option values, diff operations, MCP transports,
auth method types, plan content, compaction statuses, and more.

### `_meta` and `_`-prefixed methods

Unchanged from v1: `_meta` metadata objects on all types;
`_vendor/method` extension methods (`ExtRequest`/`ExtResponse`/
`ExtNotification`); `$/cancel_request` protocol notification.

---

## v1 → v2 Migration Summary

| Area | v1 | v2 |
|:-----|:---|:---|
| Protocol version | `1` | `2` |
| Implementation info | `clientInfo`/`agentInfo` optional | `info` required both sides |
| Auth | `authenticate` + `logout`, `id` field, `auth.logout` cap | `auth/login` + `auth/logout`, `methodId` field, gated on `authMethods` |
| Capability nesting | `loadSession`, `promptCapabilities`, `mcpCapabilities` top-level | all under `capabilities.session` |
| Session modes | `modes`, `session/set_mode`, `current_mode_update` | removed |
| Resume | `session/load` (replay) + `session/resume` (no replay), separate gates | unified `session/resume` with `replayFrom` cursor |
| Prompt completion | `session/prompt` response `stopReason` | response is empty ack; `state_update → idle` carries `stopReason` |
| Message IDs | optional in chunks | required in all chunks |
| Message variants | `*_message_chunk` only | + `user_message`/`agent_message`/`agent_thought` whole-message upserts |
| Tool call start | `tool_call` + `tool_call_update` | single `tool_call_update` upsert + `tool_call_content_chunk` |
| Tool cancelled | — | `cancelled` status; also on plan entries |
| Diffs | `{path, oldText?, newText}` | `{changes: DiffChange[], patch?: {format, text}}` |
| Terminals | client-owned `terminal/*` methods | agent-owned; `terminal_update`/`terminal_output_chunk` |
| Client fs | `fs/read_text_file`, `fs/write_text_file` | removed |
| Plan | `plan` full replacement (+unstable ID-addressed) | `plan_update` ID-addressed only |
| Permission request | `toolCall` field (tool calls only) | `title` + `subject` (tool_call/command/custom) |
| Config values | untyped string or `{type: boolean}` | typed `{type: id\|boolean\|custom}` required |
| MCP transports | stdio (mandatory), http, sse | stdio (opt-in), http, acp; sse removed |
| `mcpServers` in session/new | required | optional |
| StopReason set | closed | open (`_` custom values) |
| Enums | closed sets | open sets with `_` extension convention |

---

## References

- [ACP Protocol docs (v2 draft)](https://agentclientprotocol.com/protocol/v2/draft/initialization)
- [Repository](https://github.com/agentclientprotocol/agent-client-protocol) — `schema/v2/`
- [v2 schema.json](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v2/schema.json) / [schema.unstable.json](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v2/schema.unstable.json)
- [v2 meta.json](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v2/meta.json) (method ↔ name mapping)
- [CHANGELOG](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/CHANGELOG.md) and [schema/v2/CHANGELOG.md](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v2/CHANGELOG.md)
- [JSON-RPC batch guidance RFD for v2](https://agentclientprotocol.com/rfds/) — see repo `docs/` RFDs
- Sibling file: [SPEC_v1.md](./SPEC_v1.md) — stable protocol v1
