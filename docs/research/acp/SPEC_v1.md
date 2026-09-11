# Agent Client Protocol (ACP) — Protocol v1 Specification

Reference for ACP protocol version `1`, based on the `main` branch of
[agentclientprotocol/agent-client-protocol](https://github.com/agentclientprotocol/agent-client-protocol)
and the v1 JSON Schema artifacts (`schema/v1/`).

**Protocol version:** `1` (integer, negotiated during `initialize`)
**Schema artifact:** `schema-v1.21.0` (2026-08-20) — `schema/v1/schema.json` (stable) + `schema/v1/schema.unstable.json`
**Rust runtime crate:** `agent-client-protocol` 1.6.0 (2026-07-21)
**Transport:** JSON-RPC 2.0 over NDJSON on stdio (default) or TCP
**License:** Apache 2.0

ACP is a bidirectional JSON-RPC 2.0 protocol between **Agents** (AI-powered code
assistants) and **Clients** (editors, IDEs, orchestrators). Requests have an `id`
and expect a response; notifications omit `id`. Wire compatibility is determined
by the `protocolVersion` exchanged during `initialize` — schema artifact versions
track SDK-facing structure, not wire compatibility.

```
Client ──stdin──▶ Agent    (client requests/notifications)
Client ◀──stdout── Agent   (agent responses/requests/notifications)
```

**Stability model:** features ship as `unstable` (present in
`schema.unstable.json`, descriptions marked **UNSTABLE**) until stabilized into
`schema.json`. Unstable features may change or be removed at any time.

---

## Method Surface (schema v1 meta.json)

### Agent methods (client → agent)

| Method | Status | Capability gate |
|:-------|:-------|:----------------|
| `initialize` | stable | required, always first |
| `authenticate` | stable | only if `authMethods` non-empty |
| `session/new` | stable | required |
| `session/load` | stable | `loadSession` (top-level legacy flag) |
| `session/resume` | stable | `sessionCapabilities.resume` |
| `session/list` | stable | `sessionCapabilities.list` |
| `session/delete` | stable | `sessionCapabilities.delete` |
| `session/close` | stable | `sessionCapabilities.close` |
| `session/prompt` | stable | required |
| `session/cancel` | stable | required (notification) |
| `session/set_mode` | stable | `modes` returned in session response |
| `session/set_config_option` | stable | `configOptions` returned in session response |
| `logout` | stable | `auth.logout` |
| `session/fork` | unstable | `sessionCapabilities.fork` |
| `providers/list`, `providers/set`, `providers/disable` | unstable | `providers` |
| `nes/*` (start, suggest, accept, reject, close) | unstable | `nes` |
| `document/didOpen`, `didChange`, `didSave`, `didClose`, `didFocus` | unstable | matching `nes.document*` caps |
| `mcp/message` | unstable | `mcpCapabilities.acp` |

### Client methods (agent → client)

| Method | Status | Capability gate |
|:-------|:-------|:----------------|
| `session/update` | stable | required (notification) |
| `session/request_permission` | stable | required |
| `fs/read_text_file` | stable | `fs.readTextFile` |
| `fs/write_text_file` | stable | `fs.writeTextFile` |
| `terminal/create` | stable | `terminal: true` |
| `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, `terminal/release` | stable | `terminal: true` |
| `elicitation/create`, `elicitation/complete` | stable (schema 1.21.0) | `elicitation.form` / `elicitation.url` |
| `mcp/connect`, `mcp/message`, `mcp/disconnect` | unstable | `mcpCapabilities.acp` |

### Protocol-level notifications

| Method | Direction | Status |
|:-------|:----------|:-------|
| `$/cancel_request` | either | stable — cancels any in-flight request by `id` |

---

## Protocol Lifecycle

### Phase 1: Initialization

```
Client ──▶ initialize(protocolVersion, clientCapabilities, clientInfo?)
Client ◀── {protocolVersion, agentCapabilities, authMethods, agentInfo?}
```

If the returned `protocolVersion` differs from what the client supports, the
client MUST disconnect.

### Phase 2: Authentication (optional)

If `authMethods` is non-empty, the client calls `authenticate` with one of the
advertised `methodId`s. Auth method types:

- `{type: "terminal", ...}` — client runs the agent interactively in a terminal;
  never passed to `authenticate`. Only advertised when the client sent
  `clientCapabilities.auth.terminal: true`.
- `{type: "agent", id, name, description?}` — the default; agent handles auth
  itself via `authenticate`.

`logout` (capability `auth.logout`) terminates the authenticated session.

### Phase 3: Session Setup

```
Client ──▶ session/new(cwd, mcpServers, additionalDirectories?)
Client ◀── {sessionId, modes?, configOptions?}
```

### Phase 4: Prompt/Response Cycle

```
Client ──▶ session/prompt(sessionId, prompt)
Agent  ──▶ session/update(sessionId, update)     ← notifications (no id)
Agent  ──▶ session/update(sessionId, update)     ← ...repeated...
Agent  ──▶ session/request_permission(...)        ← if approval needed (has id)
Client ──▶ {outcome}                              ← permission response
Client ◀── {stopReason, usage?}                   ← response to session/prompt
```

### Phase 5: Shutdown

Close the transport (stdin EOF / TCP close). Use `session/close` (capability
`sessionCapabilities.close`) to free one session's resources without ending
the process.

---

## Client → Agent Methods

### `initialize`

```typescript
type InitializeRequest = {
  protocolVersion: number;          // latest version the client supports (1)
  clientCapabilities: {
    fs?: { readTextFile?: boolean; writeTextFile?: boolean };
    terminal?: boolean;
    session?: {
      compaction?: {};              // unstable
      configOptions?: {};
    };
    plan?: {};                      // unstable: plan_update/plan_removed
    auth?: { terminal?: boolean };
    elicitation?: { form?: {}; url?: {} };
    nes?: {};                       // unstable
    positionEncodings?: string[];   // unstable
  };
  clientInfo?: { name: string; version: string; title?: string };
};

type InitializeResponse = {
  protocolVersion: number;
  agentCapabilities: {
    loadSession?: boolean;
    promptCapabilities?: { image?: boolean; audio?: boolean; embeddedContext?: boolean };
    mcpCapabilities?: { http?: boolean; sse?: boolean; acp?: boolean };
    sessionCapabilities?: {
      list?: {}; delete?: {}; additionalDirectories?: {};
      fork?: {}; resume?: {}; close?: {};
    };
    auth?: { logout?: {} };
    providers?: {};                 // unstable
    nes?: {};                       // unstable
    positionEncoding?: string;      // unstable
  };
  authMethods: AuthMethod[];        // empty if no auth needed
  agentInfo?: { name: string; version: string; title?: string };
};
```

**Example:**
```json
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":true},"clientInfo":{"name":"cydo","version":"0.1.0"}}}
```

---

### `authenticate`

```typescript
type AuthenticateRequest  = { methodId: string };
type AuthenticateResponse = {};
```

---

### `session/new`

```typescript
type NewSessionRequest = {
  cwd: string;                          // absolute path
  mcpServers: McpServer[];              // required
  additionalDirectories?: string[];     // requires sessionCapabilities.additionalDirectories
};

type NewSessionResponse = {
  sessionId: string;
  modes?: SessionModeState;
  configOptions?: SessionConfigOption[];
};
```

---

### `session/load` vs `session/resume`

Both restore state; they differ in history replay:

- **`session/load`** (capability `loadSession`): the agent replays conversation
  history via `session/update` notifications (`user_message_chunk`,
  `agent_message_chunk`, tool calls) before responding.
- **`session/resume`** (capability `sessionCapabilities.resume`): resumes
  **without** replaying previous messages.

```typescript
type LoadSessionRequest = { sessionId: string; cwd: string; mcpServers: McpServer[];
                            additionalDirectories?: string[] };
type LoadSessionResponse = { modes?: SessionModeState; configOptions?: SessionConfigOption[] };

type ResumeSessionRequest = { sessionId: string; cwd: string; mcpServers?: McpServer[];
                              additionalDirectories?: string[] };
type ResumeSessionResponse = { modes?: SessionModeState; configOptions?: SessionConfigOption[] };
```

Note: `session/load` is gated by the top-level `loadSession` flag rather than
`sessionCapabilities` — a known inconsistency scheduled for unification in a
future protocol version (v2 unifies both into `session/resume`).

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
  updatedAt?: string;                 // ISO 8601
};

type DeleteSessionRequest  = { sessionId: string };
type DeleteSessionResponse = {};
```

---

### `session/prompt`

```typescript
type PromptRequest = {
  sessionId: string;
  prompt: ContentBlock[];
};

type PromptResponse = {
  stopReason: StopReason;
  usage?: Usage;                      // unstable
};

type StopReason =
  | "end_turn"          // turn ended successfully
  | "max_tokens"        // token limit reached
  | "max_turn_requests" // agent request limit between user turns reached
  | "refusal"           // agent refused; prompt excluded from next turn
  | "cancelled";        // cancelled via session/cancel (MUST be returned)
```

The response arrives **after the turn completes**. All agents MUST support
`text` and `resource_link` content blocks in prompts; other block types require
`promptCapabilities`.

---

### `session/cancel`

Notification (no `id`). The in-flight `session/prompt` MUST return
`stopReason: "cancelled"`, and the client MUST answer any pending
`session/request_permission` with `{outcome: "cancelled"}`.

```json
{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"sess_001"}}
```

---

### `session/set_mode` / `session/set_config_option`

```typescript
type SetSessionModeRequest  = { sessionId: string; modeId: string };
type SetSessionModeResponse = {};

type SetSessionConfigOptionRequest = {
  sessionId: string;
  configId: string;
  value:
    | { type: "boolean"; value: boolean }
    | { value: string };              // SessionConfigValueId; default variant (no `type` on the wire)
};

type SetSessionConfigOptionResponse = { configOptions: SessionConfigOption[] };
```

---

### `logout`

```typescript
type LogoutRequest  = {};
type LogoutResponse = {};
```

Terminates the current authenticated session. Requires `auth.logout`.

---

### `session/fork` (unstable)

Creates a new session derived from an existing one, preserving conversation
context. Requires `sessionCapabilities.fork`.

```typescript
type ForkSessionRequest  = { sessionId: string; cwd?: string; mcpServers?: McpServer[] };
type ForkSessionResponse = { sessionId: string; modes?: SessionModeState;
                             configOptions?: SessionConfigOption[] };
```

---

## Agent → Client Methods

### `session/update`

Notification; the primary streaming mechanism.

```typescript
type SessionNotification = {
  sessionId: string;
  update: SessionUpdate;              // discriminated by `sessionUpdate`
};
```

See [session/update Variants](#sessionupdate-variants).

---

### `session/request_permission`

```typescript
type RequestPermissionRequest = {
  sessionId: string;
  toolCall: ToolCallUpdate;           // the tool call needing approval
  options: PermissionOption[];        // at least one
};

type PermissionOption = {
  optionId: string;
  name: string;
  kind: "allow_once" | "allow_always" | "reject_once" | "reject_always";
};

type RequestPermissionOutcome =
  | { outcome: "selected"; optionId: string }
  | { outcome: "cancelled" };
```

On `session/cancel`, the client MUST respond `cancelled` to all pending
permission requests.

---

### `fs/read_text_file` / `fs/write_text_file`

```typescript
type ReadTextFileRequest  = { sessionId: string; path: string; line?: number; limit?: number };
type ReadTextFileResponse = { content: string };

type WriteTextFileRequest  = { sessionId: string; path: string; content: string };
type WriteTextFileResponse = {};
```

Client-side file access — the agent delegates to the client when it advertises
`fs.readTextFile` / `fs.writeTextFile`.

---

### `terminal/*` (client-owned terminals)

The client owns the terminal; the agent drives it via requests:

```typescript
type CreateTerminalRequest = {
  sessionId: string; command: string; args?: string[]; cwd?: string;
  env?: EnvVariable[]; outputByteLimit?: number;
};
type CreateTerminalResponse = { terminalId: string };

type TerminalOutputRequest  = { sessionId: string; terminalId: string };
type TerminalOutputResponse = { output: string; truncated: boolean;
                                exitStatus?: { exitCode?: number; signal?: string } };

type WaitForTerminalExitResponse = { exitCode?: number; signal?: string };
type KillTerminalResponse        = {};
type ReleaseTerminalResponse     = {};
```

Terminals can be embedded in tool call output via
`{type: "terminal", terminalId: "..."}` content.

---

## session/update Variants

All variants share the envelope `{sessionId, update: {sessionUpdate: "<name>", ...}}`.

| Variant | Status | Payload |
|:--------|:-------|:--------|
| `user_message_chunk` | stable | `ContentChunk` |
| `agent_message_chunk` | stable | `ContentChunk` |
| `agent_thought_chunk` | stable | `ContentChunk` |
| `tool_call` | stable | `ToolCall` |
| `tool_call_update` | stable | `ToolCallUpdate` |
| `plan` | stable | `Plan` (full replacement) |
| `plan_update` | unstable | `PlanUpdate` (ID-addressed) |
| `plan_removed` | unstable | `{planId}` |
| `available_commands_update` | stable | `{availableCommands}` |
| `current_mode_update` | stable | `{currentModeId}` |
| `config_option_update` | stable | `{configOptions}` |
| `session_info_update` | stable | `{title?, updatedAt?}` (null clears) |
| `usage_update` | stable | `UsageUpdate` |
| `notice` | unstable | `{severity, title, description?}` |
| `compaction_update` | unstable | `CompactionUpdate` |
| `compaction_summary_chunk` | unstable | `{compactionId, content}` |

### `ContentChunk`

```typescript
type ContentChunk = {
  content: ContentBlock;
  messageId?: string | null;   // optional in v1; same id ⇒ same message
};
```

### `ToolCall` / `ToolCallUpdate`

```typescript
type ToolCall = {
  toolCallId: string;
  title: string;
  name?: string;               // unstable: programmatic tool name
  kind?: ToolKind;
  status?: ToolStatus;
  content?: ToolCallContent[];
  locations?: { path: string; line?: number }[];
  rawInput?: object;
  rawOutput?: object;
};

type ToolCallUpdate = {        // partial update; all fields optional except the id
  toolCallId: string;
  title?: string; name?: string; kind?: ToolKind; status?: ToolStatus;
  content?: ToolCallContent[]; locations?: ToolLocation[];
  rawInput?: object; rawOutput?: object;
};

type ToolKind = "read" | "edit" | "delete" | "move" | "search"
              | "execute" | "think" | "fetch" | "switch_mode" | "other";

type ToolStatus = "pending" | "in_progress" | "completed" | "failed";

type ToolCallContent =
  | { type: "content";  content: ContentBlock }
  | { type: "diff";     path: string; oldText?: string; newText: string }
  | { type: "terminal"; terminalId: string };
```

`tool_call` announces a new invocation; `tool_call_update` reports progress and
completion, correlated by `toolCallId`. There is no `cancelled` status in v1
(added in v2).

### `plan` (full replacement)

```typescript
type Plan = {
  entries: {
    content: string;
    priority: "high" | "medium" | "low";
    status: "pending" | "in_progress" | "completed";
  }[];
};
```

Each `plan` update replaces the entire plan. The ID-addressed
`plan_update`/`plan_removed` pair (unstable; requires client `plan` capability)
targets a plan by `planId` and additionally supports `file` and `markdown`
content variants.

### `usage_update`

```typescript
type UsageUpdate = {
  used: number;                 // tokens currently in context
  size: number;                 // total context window
  cost?: { amount: number; currency: string };   // ISO 4217
};
```

### `compaction_update` (unstable)

ID-addressed context-compaction upsert; requires client
`session.compaction` capability.

```typescript
type CompactionUpdate = {
  compactionId: string;
  status: "in_progress" | "completed" | "failed" | "cancelled";
  summary?: ContentBlock[] | null;   // patch semantics; [] clears
  error?: string | null;             // only valid with "failed"
};
```

---

## Content Blocks

MCP-compatible; appear in prompts, streamed output, and tool results.

```typescript
type ContentBlock =
  | { type: "text"; text: string; annotations?: Annotations }
  | { type: "image"; data: string; mimeType: string; uri?: string; annotations?: Annotations }
  | { type: "audio"; data: string; mimeType: string; annotations?: Annotations }
  | { type: "resource_link"; uri: string; name: string; description?: string;
      mimeType?: string; size?: number; title?: string; annotations?: Annotations }
  | { type: "resource"; resource: EmbeddedResource; annotations?: Annotations };
```

Text and resource_link MUST be supported by all agents in prompts; image /
audio / resource require the corresponding `promptCapabilities` flags.

---

## Session Config Options

```typescript
type SessionConfigOption = {
  id: string;
  name: string;
  description?: string;
  category?: "mode" | "model" | "model_config" | "thought_level" | string;
  type: "select" | "boolean";
  // select:
  currentValue?: string;
  options?: SelectOption[] | SelectGroup[];
  // boolean:
  currentValue?: boolean;
};

type SelectOption = { name: string; value: string; description?: string };
type SelectGroup  = { group: string; name: string; options: SelectOption[] };
```

Categories are UX hints only (`_`-prefixed names are reserved for custom use);
unknown categories MUST be handled gracefully.

---

## MCP Servers

```typescript
type McpServer =
  | { type: "stdio"; name: string; command: string; args: string[]; env: EnvVariable[] }  // MUST support
  | { type: "http";  name: string; url: string; headers: HttpHeader[] }   // mcpCapabilities.http
  | { type: "sse";   name: string; url: string; headers: HttpHeader[] }   // mcpCapabilities.sse
  | { type: "acp";   name: string; ... }                                  // unstable, mcpCapabilities.acp
```

The unstable MCP-over-ACP surface (`mcp/connect`, `mcp/message`,
`mcp/disconnect`) lets the client host MCP servers the agent talks to over the
ACP channel.

---

## Elicitation (stable since schema 1.21.0)

Agent → client request for structured user input, in two modes:

```typescript
type CreateElicitationRequest = {
  message: string;
  mode: "form" | "url" | string;      // `_`-prefixed custom modes allowed
  // form mode:
  requestedSchema?: {                  // JSON Schema with primitive-typed properties
    type: "object"; title?: string; properties: object; required?: string[];
  };
  // url mode:
  elicitationId?: string;
  url?: string;
  // scope (either):
  //   { sessionId, toolCallId? }  — session-scoped (optionally tool-call-scoped)
  //   { requestId }               — request-scoped (pre-session, e.g. auth)
};

type CreateElicitationResponse =
  | { action: "accept";  content?: object }
  | { action: "decline" }
  | { action: "cancel" }
  | { action: string };               // custom `_`-prefixed actions
```

`elicitation/complete` notifies the agent when a URL-mode elicitation finishes.

---

## Error Handling

Standard JSON-RPC 2.0 error object. ACP-defined codes:

| Code | Name | Meaning |
|:-----|:-----|:--------|
| `-32700` | Parse error | Invalid JSON |
| `-32600` | Invalid request | Not a valid JSON-RPC request |
| `-32601` | Method not found | Unknown method |
| `-32602` | Invalid params | Invalid method parameters |
| `-32603` | Internal error | Implementation-defined |
| `-32800` | Request cancelled | Aborted via `$/cancel_request` or shutdown |
| `-32000` | Authentication required | Auth needed before this operation |
| `-32002` | Resource not found | E.g., session not found |

---

## Extensibility

### `_meta`

All objects carry an optional `_meta` object (string keys, arbitrary values)
for implementation-specific metadata.

### Vendor extensions

Custom methods use `_`-prefixed names (`_vendor/method`), typed as
`ExtRequest` / `ExtResponse` / `ExtNotification`. `_`-prefixed enum values are
free for custom use; unknown non-`_` values are reserved for future ACP
variants.

### `$/cancel_request`

Cancels any in-flight JSON-RPC request by `id`. The receiver MUST eventually
respond with a valid response (possibly partial) or a `-32800` error.

---

## Version History (v1 wire protocol)

| Schema | Date | Key changes |
|:-------|:-----|:------------|
| 1.21.0 | 2026-08-20 | Stabilize elicitation + terminal auth; compaction updates (unstable) |
| 1.20.0 | 2026-07-21 | Tool call `name` (unstable) |
| 1.19.x | 2026-07 | Elicitation enum option descriptions |
| 1.18.0 | 2026-07-06 | Stabilize boolean config options; reject malformed protocol fields |
| 1.17.0 | 2026-06-29 | Stabilize request cancellation |
| 1.16.0 | 2026-06-24 | Stabilize `model` config category |
| 1.15.0 | 2026-06-24 | Boolean config option capabilities |
| 1.14.0 | 2026-06-18 | Model config category (unstable); rust crate exposes v1-only module |
| 1.13.x | 2026-06 | Stabilize optional message IDs, session usage updates, session/delete; additionalDirectories |
| 1.3–1.12 | 2026-03→06 | Stabilize logout, session/close, session/resume |
| 0.12.2 | 2026-04-23 | Stabilize session/close, session/resume |
| 0.11.x | 2026-03→04 | Elicitation draft, logout draft, providers draft, NES draft |
| 0.10.x | 2025-12→2026-02 | Session config options, session/fork draft, usage_update, `$/cancel_request` |
| 0.9.0 | 2025-12-01 | `_meta` clarification |
| 0.8.0 | 2025-11-28 | Schema flattening |
| 0.7.0 | 2025-11-25 | Stable/unstable schema split |

The **protocol version** remains `1` throughout. Schema semver tracks artifact
maturity, not wire compatibility.

---

## References

- [ACP Protocol docs (v1)](https://agentclientprotocol.com/protocol/overview)
- [Repository](https://github.com/agentclientprotocol/agent-client-protocol) — `schema/v1/`
- [v1 schema.json](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v1/schema.json) / [schema.unstable.json](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v1/schema.unstable.json)
- [v1 meta.json](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v1/meta.json) (method ↔ name mapping)
- [CHANGELOG](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/CHANGELOG.md) and [schema/v1/CHANGELOG.md](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v1/CHANGELOG.md)
- [TypeScript SDK](https://github.com/agentclientprotocol/typescript-sdk) / [Python SDK](https://github.com/agentclientprotocol/python-sdk) / [Rust crate](https://docs.rs/agent-client-protocol)
- Sibling file: [SPEC_v2.md](./SPEC_v2.md) — next-generation protocol (draft)
