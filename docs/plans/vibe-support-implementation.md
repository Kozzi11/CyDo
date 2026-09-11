# Implementation Plan: Mistral Vibe CLI Support (`vibe-acp` driver)

Companion to `docs/plans/mistral-vibe-support.md` (feasibility analysis,
already reviewed). This document is the concrete implementation plan for the
selected **`vibe-acp`** integration path.

**Test gate:** every commit must pass `nix flake check` — it builds the
backend, builds the frontend, runs unit tests, and runs the full Playwright
E2E matrix. No work is complete until it passes.

---

## Part 0: Spike (do first, ~½ day)

The plan assumes a wire dialect that must be confirmed before the driver RPC
structs are finalized. Capture one real `vibe-acp` session through a
tee/wrapper shim (precedent: `tests/extra-fields-wrapper.sh`) and answer:

| # | Question | Decides |
|---|----------|---------|
| S1 | `initialize` result: `protocolVersion`, `agentCapabilities` (`loadSession`, `mcpCapabilities`, `sessionCapabilities`), `agentInfo` | RPC struct fields, resume capability flag |
| S2 | Exact `session/update` variant names for the pinned `agent-client-protocol==0.11.0` (vs. schema 0.11.3-era v1 spec in `docs/research/acp/SPEC_v1.md`) | `VibeAcpRouter` dispatch table |
| S3 | Does `session/new` `mcpServers` actually load tools? | Whether the `config.toml` fallback in Step 3 is required |
| S4 | Does a fresh `vibe-acp` process `session/load` a session from a previous process? Replay update shape? | Whether Step 8 (resume) lands in v1 |
| S5 | On-disk session format under `$VIBE_HOME` (layout, per-line schema) | Step 9 (history) feasibility |
| S6 | Do `AGENTS.md` / config system prompts apply to ACP sessions? | `supportsDeveloperPrompt` value |
| S7 | Headless behavior in bwrap `--clearenv`: trust-folder prompt, update prompt, TTY assumptions | Pre-seed recipe in Step 3 |
| S8 | Current Devstral 2 / Mistral Medium model ids | Model defaults in Step 2 |

Record findings in `docs/research/vibe-acp-wire.md` (new file, same style as
`docs/research/acp/SPEC.md`).

---

## Part 1: Core registration (small additive commits, e2e-neutral)

### Commit 1.1 — `AgentDriver.vibe` + registry entry

**`source/cydo/runtime/config/package.d`**
- `enum AgentDriver { claude, codex, copilot, vibe }`.
- `driverSupportsEffort`: add `case AgentDriver.vibe: return false;`
  (vibe has a `thinking` config option, not a launch flag; revisit in Step 10).

**`source/cydo/agent/drivers/registry.d`**
- Add after the copilot entry:
  ```d
  AgentRegistration("vibe", "Mistral Vibe",
      function Agent() { import cydo.agent.drivers.vibe : VibeAgent; return new VibeAgent(); },
  ),
  ```
- Add a `version (unittest)` forward declaration stub (see Step 2) so this
  commit compiles before `vibe.d` exists — or land 1.1 and 2.1 together if
  preferred (they are small; landing together is fine).

**`source/cydo/workflow/sessions/task_runner.d`** (~line 1473)
- Extend the `final switch (ta.driver)` install-hint block:
  ```d
  case AgentDriver.vibe:
      installHint = "`uv tool install mistral-vibe` (or brew / GitHub release)";
      break;
  ```

**`source/cydo/runtime/launch/environment.d`**
- Add to the rules list in the first unittest (~line 96):
  ```d
  NativeHistoryRule(AgentDriver.vibe, "VIBE_HOME", ".vibe", null),
  ```

**`source/cydo/server/app.d`** — `isKnownPromptParityAgent` (line 5377):
add `"vibe"` to the list (prompt-parity unit test then covers the new driver
once its session class exists).

Note: `config_resolution.d` needs **no changes** — `resolveConfig` pass 2
synthesizes `agents["vibe"]` from the registry, and driver-name inference
(`to!AgentDriver(reg.name)`) picks up the new enum member automatically.

### Commit 1.2 — type-level test parity

Run `nix flake check`. Fix any `final switch`/exhaustive-switch compile
errors the new enum member surfaces outside the files above (grep
`AgentDriver\.` and `switch (.*driver` to find them). This is deliberately a
separate commit so Part 2 never mixes refactor noise with driver logic.

---

## Part 2: `vibe.d` — the driver

New file `source/cydo/agent/drivers/vibe.d`. Two classes:
`VibeAgent : Agent` and `VibeSession : AgentSession`.

### 2.1 `VibeAgent` skeleton

```d
module cydo.agent.drivers.vibe;

class VibeAgent : Agent
{
    void configureSandbox(ref SandboxPaths paths, ref string[string] env);
    @property string gitName();            // "Mistral Vibe"
    @property string gitEmail();           // "noreply@mistral.ai"
    override @property AgentDriver driver();          // AgentDriver.vibe
    override @property NativeHistoryRule nativeHistoryRule();
    //   → NativeHistoryRule(AgentDriver.vibe, "VIBE_HOME", ".vibe", null)
    string executableName(string[string] env);
    //   → effectiveEnvValue(env, "CYDO_VIBE_BIN", "vibe-acp")
    AgentSession createSession(int tid, string resumeSessionId,
        ProcessLaunch launch, SessionConfig config);
    string extractResultText(string line);   // parse agnostic "turn/result"
    string extractAssistantText(string line);// parse agnostic item/started text
    string extractUserText(string line);     // parse agnostic user_message items
    DiscoveredSession[] enumerateAllSessions(const ref NativeHistoryProfile);
    SessionMeta readSessionMeta(const ref DiscoveredSession);
    string matchProject(const ref DiscoveredSession, const string[]);
    void setModelAliases(ModelSpec[string] aliases);
    ModelSpec resolveModelSpec(string modelClass);
    string historyPath(string, const ref NativeHistoryProfile);
    void registerHistoryPath(string, string, const ref NativeHistoryProfile);
    string createHistoryForkDestination(string, string, const ref NativeHistoryProfile);
    void resetHistoryReplay();
    TranslatedEvent[] translateHistoryLine(string line, int lineNum);
    TranslatedEvent[] translateLiveEvent(string rawLine);
    bool isTurnResult(string rawLine);
    bool isUserMessageLine(string rawLine);
    bool isAssistantMessageLine(string rawLine);
    string rewriteSessionId(string line, string oldId, string newId);
    PersistedHistoryBoundary[] extractPersistedHistoryBoundaries(string, int = 0);
    InterruptedToolCallRepair repairInterruptedToolCall(string[], string, string);
    bool forkIdMatchesLine(string, int, string);
    bool isForkableLine(string line);
    @property bool needsBash();               // true
    @property bool supportsFileRevert();      // false
    @property bool supportsDeveloperPrompt(); // per S6, likely false initially
    RewindResult rewindFiles(string, string, ProcessLaunch); // unsupported stub
    OneShotHandle completeOneShot(string prompt, string modelClass, ProcessLaunch);
    @property string lastMcpConfigPath();
}
```

### 2.2 Sandbox & profile (`configureSandbox` / `nativeHistoryRule`)

Follow `CopilotAgent.configureSandbox` exactly:

- Mount vibe executable + CyDo binary read-visible
  (`executableMountPaths(resolveExecutablePath(...))`, `cydoBinaryDir()`).
- Pass through (not set) `MISTRAL_API_KEY`, `VIBE_HOME`, `HTTPS_PROXY`,
  `NO_PROXY`, `PATH` — via the `passthrough()` helper pattern.
- Never write `VIBE_HOME` itself here; the launch phase materializes the
  native-history profile root from the rule (`resolveNativeHistoryProfile`),
  matching the copilot/claude contract ("configureSandbox must not turn it
  into a native-history mount" — pinned by `CopilotAgent`'s sandbox test).
- Add `env["VIBE_UPDATE_CHECKS"] = ...`? No — vibe has no such env; update
  suppression goes in the generated `config.toml` (Step 2.4).

### 2.3 `resolveModelSpec`

```d
private static string defaultModelForClass(string modelClass)
{
    switch (modelClass)
    {
        case "small":  return "devstral-2-small";   // pin via S8
        case "medium": return "devstral-2";          // pin via S8
        case "large":  return "mistral-medium-3.5";  // pin via S8
        default:       return modelClass;            // pass through
    }
}
```
Copy the Copilot override-precedence unittest block verbatim (tests 14–18
in `copilot.d`) — the semantics are identical.

### 2.4 `VIBE_HOME` bootstrap + MCP config (`createSession`, pre-spawn)

`createSession` runs, in order:

1. **Resolve profile root.** `launch.nativeHistoryProfile.root` is the
   effective `$VIBE_HOME` (materialized by `resolveNativeHistoryProfile`).
2. **Write `config.toml`** if absent (idempotent, don't clobber user config
   in a shared profile — write only what's needed):
   ```toml
   # managed by CyDo — per-task agent profile
   enable_update_checks = false
   active_model = "<resolved model>"        # only when config.model set

   [[mcp_servers]]
   name = "cydo"
   transport = "stdio"
   command = "<cydoBinaryPath()>"
   args = ["mcp-server"]

   [mcp_servers.env]
   CYDO_TID = "<tid>"
   CYDO_SOCKET = "<config.mcpSocketPath>"
   CYDO_CREATABLE_TYPES = "<config.creatableTaskTypes>"
   CYDO_SWITCHMODES = "<config.switchModes>"
   CYDO_HANDOFFS = "<config.handoffs>"
   CYDO_INCLUDE_TOOLS = "<join(includeTools, \",\")>"
   ```
   (Env contract mirrors `generateCopilotMcpConfig`; S3 decides whether
   `session/new mcpServers` can replace this file entirely — prefer the
   file, it is version-stable.)
   Store the path in `lastMcpConfigPath_` — actually store the *profile
   config path*; the existing cleanup-on-exit contract in `app.d` deletes
   the tracked file, so track the generated file only when it was created
   fresh (or track `null` when pre-existing — delete nothing).
3. **Pre-seed `trusted_folders.toml`** (`$VIBE_HOME/trusted_folders.toml`):
   add the session work dir (worktree path or project path) so vibe never
   blocks on its trust prompt under bwrap (S7 verifies).
4. **Spawn args.**
   ```d
   string[] vibeArgs = [vibeBin, "--stdio"];   // S2 confirms invocation shape
   auto args = launch.cmdPrefix !is null
       ? launch.cmdPrefix ~ vibeArgs : vibeArgs;
   auto server = new VibeAcpProcess(args);
   ```
   Per-session process (one `vibe-acp` per task session) — no workspace
   pool; Codex's multi-session pool is unnecessary complexity here.
5. Client-generated session UUID (`randomUUID`) when `resumeSessionId`
   is empty, else the resume id; `attachSession(...)` mirrors
   `copilot.d`'s shape.

### 2.5 `VibeAcpProcess` — JSON-RPC transport

Model on `AppServerProcess` (codex) + `SdkProcess` (copilot):

- `AgentProcess(args, logName: "vibe")` with default `FramingMode.ndjson`
  (line-delimited — matches vibe-acp; S2 confirms no content-length framing).
- `JsonRpcCodec(process.connection)`; `handleRequest` →
  `jsonRpcDispatcher!IVibeAcpServer(router)`.
- Ready state machine: `starting → initializing → ready` on `initialize`
  response; `failed`/`dead` on error/exit. `onReady` queue like
  `SdkProcess.onReady`.
- Session registry: `VibeSessionHandler[string] sessions` keyed by
  sessionId.
- Server-initiated dispatch interface:
  ```d
  @RPCNamedParams
  private interface IVibeAcpServer
  {
      // Agent → client streaming notifications
      @RPCName("session/update") Promise!void sessionUpdate(SessionUpdateParams);
      // Agent → client permission request (respond auto-allow)
      @RPCName("session/request_permission") Promise!PermissionOutcome
          requestPermission(PermissionRequestParams);
      // Agent → client fs/terminal requests: respond with JSON-RPC errors
      // (method-not-found is safer than a wrong-shape result) unless S1
      // shows vibe requires them.
      // @RPCName("fs/read_text_file")  … (declare per S1 capabilities)
  }
  ```
- Shutdown: copy `SdkProcess.shutdown` verbatim including the
  orphaned-children pipe-drain rationale (comment) — `closeStdin` +
  `terminate` + `killAfterTimeout(3.seconds)` + daemon timers. This dance
  exists because Copilot/vibe-class processes spawn children that hold
  stdout fds open.

### 2.6 Handshake & session setup (in `attachSession`)

```d
server.onReady(() {
    server.sendRequest("initialize", toJson(InitializeParams(1u,
        ClientCapabilities(fsRead: true, fsWrite: true, terminal: false),
        ClientInfo("cydo", "0.1.0"))))
    .then((JsonRpcResponse resp) {
        if (resp.isError) { failStartup(...); return; }
        if (resumeSessionId.length > 0)
            sendSessionLoad(sessionId, workDir);
        else
            sendSessionNew(sessionId, workDir, config);
    });
});
```

`session/new` params per S2 (0.11.x pins `{cwd, mcpServers}`):
- `cwd` = task work dir
- On success → `session.onSessionStarted(model, workDir)` (mirrors
  `CopilotSession.onSessionStarted`): emit synthetic `session/init` with
  `agent = "vibe"`, `supports_file_revert = false`, `agent_name`,
  notify `onNativeSessionStarted`, then `drainPendingMessages()`.

### 2.7 `VibeSession : AgentSession`

Copy the `CopilotSession` skeleton and replace the event source:

- **Submission:** `sendMessage` → `session/prompt` RPC; fulfill
  `Promise!AgentSubmissionReceipt` with `appServerAccepted` when the
  response arrives (reject on JSON-RPC error) — mirrors Copilot's
  `session.send` acceptance exactly, including `PendingMessage` queueing
  while `!sessionReady_ || turnInProgress`.
  Content mapping: text blocks → `[{type:"text", text}]`; throw
  `"Unsupported content block type for Vibe: " ~ type` for images
  (`supportsImages() = false`).
- **Interrupt:** `session/cancel` **notification** (no response expected —
  do not `.then` on it). `sigint()` = `interrupt()`.
- **stop / closeStdin:** mirror Copilot (`session.abort` → here: cancel,
  then `server.shutdown()`; `gracefulShutdown_`/`forcedStop_` flags decide
  reported exit code 0 vs 1).
- **Streaming translation** (`handleSessionUpdate` switch on
  `update.sessionUpdate`, names per S2):
  | vibe update | translation |
  |---|---|
  | `agent_message_chunk` | lazy `item/started` (text) + `item/delta{text_delta}` |
  | `agent_thought_chunk` | lazy `item/started` (thinking) + `item/delta{thinking_delta}` |
  | `tool_call` | finalize active text; `item/started{tool_use}` with decomposed name/input; emit single `input_json_delta` when input non-empty |
  | `tool_call_update` (completed) | `item/completed` + `item/result` (content text; `rawOutput.content`/`detailedContent` fallback like `extractResultText` in copilot.d) |
  | `tool_call_update` with `diff` content | `item/result` with the diff block preserved (`[{type:"diff",...}]` content fragment) |
  | compaction synthetic tool_call start/end | **consume**; emit one `session/compacted` at end (title match "Compacting conversation history", S2) |
  | `user_message_chunk` | `item/started{user_message}` (load replay only) |
  | `plan` | ignore v1 |
  | `available_commands_update`, `current_mode_update` | ignore |
  | `session_info_update` | ignore v1 |
  | `usage_update` | accumulate; flush into `turn/result.usage` |
  | unknown | `makeUnrecognizedEvent("unknown vibe update: " ~ name)` |
- **Turn boundary:** when the `session/prompt` response arrives →
  `finalizeActiveTextItem()` + `finalizeAllTools()` → `turn/stop` →
  `turn/result{subtype:"success", result: lastResultText}` →
  `turnInProgress = false` → `drainPendingMessages()`.
  (Alternative per S2: if vibe emits an explicit turn-end update, prefer
  that; keep the response as backstop.)
- **cydo tool naming:** if a `tool_call` name starts with `cydo_` (vibe
  MCP naming uses underscores): strip prefix, set
  `tool_server = "cydo"`, `tool_source = "mcp"`. Identical to the
  copilot `cydo-` handling but with `_`.
- **Item IDs:** `vb-text-<turnNs>-<n>`, `vb-think-...`, `vb-tool-<toolCallId>`
  — the `cp-` pattern with a new prefix; per-turn namespace counter and
  `nextItemIndex` reset, like Copilot.
- **Raw/timestamp plumbing:** `TranslatedEvent(translated, rawJson, ts)`
  with `currentRawJson_`/`currentEventTs_` from the enclosing
  `session/update` params (Copilot's `handleEvent` pattern).

### 2.8 `completeOneShot` (titles, suggestions)

Mirror the Claude one-shot shape (simplest, no shared process needed):
spawn `vibe --prompt <prompt> --output text --max-turns 1 --yolo` (flags per
S2; `--agent auto-approve` is the alternative) as a one-shot `AgentProcess`
with `FramingMode.raw`, accumulate stdout, fulfill on exit — exactly
`ClaudeCodeAgent.completeOneShot`. Use `resolveModelSpec(modelClass).model`;
`launch.executablePath`/`cmdPrefix` respected. Keep the copilot-style guard
against concurrent self-extraction only if vibe has one (it doesn't — skip).

### 2.9 Unit tests (in-file, following driver conventions)

- Sandbox/profile test: copy `CopilotAgent`'s `configureSandbox` unittest;
  assert `VIBE_HOME` passthrough, executable mounts, and that the profile
  root is *not* mounted by `configureSandbox`.
- `resolveModelSpec` tests 14–18 verbatim.
- MCP config generation test (mirrors `generateCopilotMcpConfig` unittest):
  file created under profile root, env contract present, wrong-driver
  profile throws.
- Handshake test with a scripted `IConnection` (copy `TestCopilotConnection`
  + `drainPromiseNextTicks` harness): assert `initialize` → `session/new`
  ordering and params; synthetic `session/init` emission order vs
  `onNativeSessionStarted` (Copilot's "publish native ID once" test).
- Submission tests: accepted-once receipt; rejection resets idle state and
  drains successor; lifecycle-loss (invalidate/exit) rejects pending.
  (Port `copilot.d`'s four test blocks; they are protocol-shape-agnostic.)
- Translation tests: chunk→item-started/delta sequences; tool_call
  lifecycle; compaction-pair consumption; cydo_ prefix decomposition;
  unknown update → unrecognized event.

### Part 2 gate: `nix flake check` green (unit tests only at this point;
no e2e coverage yet — that's Part 3).

---

## Part 3: E2E infrastructure

### Commit 3.1 — Nix packaging (`flake.nix`)

Package the **static `vibe-acp` GitHub-release tarball** (no Python runtime;
mirrors `copilot-cli` at lines 154–187):

```nix
vibeVersion = "2.25.x";   # pin; bump deliberately
vibe-acp = pkgs.stdenv.mkDerivation {
  pname = "vibe-acp";
  version = vibeVersion;
  src = pkgs.fetchurl {
    # per-arch URLs like copilot's; vibe-acp-linux-x64-<ver>.tar.gz
    url = "https://github.com/mistralai/mistral-vibe/releases/download/v${vibeVersion}/vibe-acp-linux-x64-${vibeVersion}.tar.gz";
    hash = "sha256-AAAA";
  };
  nativeBuildInputs = [ pkgs.autoPatchelfHook ];
  buildInputs = [ pkgs.stdenv.cc.cc.lib ];  # static-ish binary; verify ldd
  sourceRoot = ".";
  installPhase = ''
    mkdir -p $out/lib/vibe $out/bin
    install -m755 vibe-acp $out/lib/vibe
    cat > $out/bin/vibe-acp <<EOF
    #!/bin/sh
    exec $out/lib/vibe/vibe-acp "\$@"
    EOF
    chmod +x $out/bin/vibe-acp
  '';
};
```
Alternatively `uv tool install mistral-vibe==<ver>` into a venv if the
static binary proves fragile. Also expose `vibe` itself if the one-shot path
needs it (v1 uses the binary's `--prompt` mode — verify whether `vibe-acp`
tarball includes it; PyPI route provides both entry points trivially).
Add to `devShells`/test `nativeBuildInputs` next to `copilot-cli`
(line 591) and the passthrough alias block (line 601).

### Commit 3.2 — test project wiring (`flake.nix`)

- `projectConfig` (line ~897): add
  `vibe = { agentType = "vibe"; claudeBin = null; extraNativeBuildInputs = [ vibe-acp ]; };`
- `knownAgents` (line 930): `[ "claude" "codex" "copilot" "vibe" ]`.
- In `mkIntegrationTest`'s `buildPhase`, add a `agentType == "vibe"` block
  alongside the copilot one (lines 773–796):
  ```bash
  export VIBE_HOME=/tmp/vibe-test-home
  mkdir -p $VIBE_HOME
  # provider → mock server (generic OpenAI-compatible backend)
  cat > $VIBE_HOME/config.toml <<VIBECFG
  enable_update_checks = false
  [generic]
  base_url = "http://127.0.0.1:9000/v1"
  api_key = "test-key-mock"
  VIBECFG
  ln -sf ${vibe-acp}/bin/vibe-acp /tmp/fake-bin/vibe-acp
  ```
  (Exact `[generic]` table shape per S8/config reference; the mock speaks
  OpenAI-compatible already for codex. If vibe's generic dialect needs a
  tweak, extend `tests/mock-api/server.mjs` — **no proxy needed**, unlike
  copilot.)
- Pre-seed trust for `/tmp/cydo-test-workspace` in the same block.

### Commit 3.3 — e2e config + first spec

- `tests/e2e/agent-sandbox-env.yaml`: add
  ```yaml
  agents:
    vibe:
      driver: vibe
      sandbox:
        env:
          VIBE_HOME: <rendered test home>   # follow the file's existing pattern
  ```
  (Match how the file expresses codex/copilot env; keep it consistent.)
- New `tests/e2e/vibe-basic-flow.spec.ts` — no agent tags needed (runs on
  all projects) or `vibe-only` where driver-specific:
  1. create task → send `reply with "OK"` → assert assistant bubble
  2. `run command echo hello` → tool_use block + result + final text
  3. `stall session` → stop button → session aborts cleanly
- Tag-drift check: `knownAgents` update makes unknown `vibe` tags fail eval,
  so no extra plumbing.

---

## Part 4: History, resume, polish (post-spike scope)

4. **Resume** (`session/load`): if S4 confirms cross-process resume,
   implement `sendSessionLoad` + replay handling
   (`user_message_chunk` → `item/started{user_message, is_replay:true}`).
   Otherwise `resumeSessionId` is accepted and ignored with a clear stderr
   diagnostic, and `historyPath`/`enumerateAllSessions` return
   null/empty (`supportsFileRevert` already false).
5. **History** (`translateHistoryLine` / storage parsing): only if S5 shows
   a stable parseable format. Until then `translateHistoryLine` returns
   `[]` (empty = skip line) and discovery APIs return empty arrays — the
   UI still shows history from CyDo's own event log; only native resume is
   lost.
6. **Thinking/effort**: map `config.effort` → vibe's `thinking` config
   option via `session/set_config_option` (0.11.x has it stable) or
   config.toml at session start; flip `driverSupportsEffort` to `true` and
   update the config tests.
7. **Prompt path**: settle `supportsDeveloperPrompt` from S6; if false,
   CyDo's prepend-to-user-input fallback applies automatically (no code).
8. **Docs**: README agent table row; `docs/plans/mistral-vibe-support.md`
   capability matrix update; AGENTS.md untouched.

---

## File-by-file change summary

| File | Change |
|---|---|
| `source/cydo/runtime/config/package.d` | `AgentDriver.vibe`, effort switch case |
| `source/cydo/agent/drivers/registry.d` | registry entry |
| `source/cydo/workflow/sessions/task_runner.d` | install hint |
| `source/cydo/runtime/launch/environment.d` | unittest rules list |
| `source/cydo/server/app.d` | `isKnownPromptParityAgent` |
| `source/cydo/agent/drivers/vibe.d` | **new** — VibeAgent, VibeSession, VibeAcpProcess, MCP config gen |
| `flake.nix` | vibe-acp package, project wiring, env setup |
| `tests/e2e/agent-sandbox-env.yaml` | vibe agent entry |
| `tests/e2e/vibe-basic-flow.spec.ts` | **new** — 3 starter specs |
| `tests/mock-api/server.mjs` | only if vibe's generic dialect needs handler tweaks |
| `docs/research/vibe-acp-wire.md` | **new** — spike findings |
| `docs/plans/mistral-vibe-support.md` | capability matrix updates post-spike |

## Risk register (implementation view)

- **Dialect drift** (S2): all RPC structs in one file section, one comment
  naming the pinned vibe version; treat like Copilot's versioned SDK.
- **Shutdown hangs**: copy the SdkProcess `shutdown()` dance (daemon timers,
  forced pipe close) wholesale — it exists for exactly this process class.
- **MCP env contract**: `CYDO_SOCKET`/`CYDO_TID` must reach the MCP server
  process vibe spawns; verify inside bwrap that vibe passes the env block
  through (S3/S7).
- **Trust prompt under bwrap**: pre-seeded `trusted_folders.toml` may use an
  absolute-path format that shifts under sandbox path rewriting — verify in
  the spike with the rendered sandbox path.
