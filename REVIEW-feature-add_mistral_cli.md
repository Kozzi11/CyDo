# Code Review — `feature/add_mistral_cli` vs `master`

- **Branch:** `feature/add_mistral_cli` (HEAD `98a9477`, merge-base `89c97da`)
- **Scope:** 20 commits, 53 files, +8522 / −174. The bulk is the new
  Mistral Vibe ACP driver (`source/cydo/agent/drivers/vibe.d`, 4664 lines),
  plus generic workflow/history changes, Nix packaging, mock-API support,
  and e2e enablement for a new `vibe` Playwright project.
- **Review mode:** read-only. No files were modified, and nothing was built
  or run (`nix flake check` was **not** run as part of this review).
- **Line numbers** refer to the files at branch HEAD.

## How to use this document (for implementing agents)

- Each finding has an ID (`V-*` vibe driver, `G-*` generic/core,
  `T-*` tests/infra, `D-*` docs/process), a severity, the location, the
  problem, why it matters, and a suggested fix.
- Severity: **blocker** (must fix before merge) · **major** (should fix
  before merge) · **minor** (fix or ticket) · **nit**.
- Items marked **needs verification** depend on vibe runtime behaviour that
  could not be confirmed from the code alone. Verify against the pinned
  `mistral-vibe` before changing behaviour.
- AGENTS.md rules apply to every fix: `nix flake check` is the mandatory gate,
  `--no-verify` is banned, tests must drive the real `vibe-acp` binary through
  `tests/mock-api/`, and commits follow `type(scope): summary`. Split
  unrelated fixes into separate commits.
- Suggested order:
  1. T-7, so cell names match master again.
  2. T-1, to get the gate green.
  3. V-1, V-2/V-3, V-4, V-5, V-6, G-1, T-2, T-4, T-3.
  4. Everything else.

---

## Summary

The driver is carefully written and extensively commented. It closely mirrors
the Copilot/SDK driver shape and has good in-file unit coverage of the ACP
handshake, chunk/item identity, tool lifecycle, compaction, replay
suppression, effort mapping and fork-destination shape. The e2e matrix was
broadened substantially.

The main risks are lifecycle and environment issues that the unit fixtures
cannot see: `TestVibeAcpProcess` overrides `shutdown()`, and the e2e
`config.toml` pins the model and pre-creates the profile. In particular:

1. A `vibe-acp` process leaks on every startup failure (V-1).
2. CyDo's per-task model selection is effectively ignored. The driver also
   writes into the user's real `~/.vibe` (V-2, V-3).
3. The one-shot path runs `vibe --yolo` with tools enabled, unlike Claude's
   `--tools ""` (V-4).
4. History replay emits a premature `turn/result` for assistant messages
   that have both text and tool calls (V-5).
5. A history line can make the unsandboxed backend read any file path (V-6).
6. The keep_context reframe rewrites history in a way that can corrupt it
   (G-1).
7. On the process side, the merge commit was made with `--no-verify`
   (T-1). Several vibe-reachable tests are weaker than they appear: the
   continuation context check is vacuous (T-2), a shared test was rewritten
   with less coverage (T-3), and the mock answers unsupported intents with
   the success sentinel `Done.` (T-4).

### Findings index

| Severity | IDs |
|---|---|
| blocker | V-1, T-1 |
| major | V-2, V-3, V-4, V-5, V-6, G-1, T-2, T-3, T-4, T-5 |
| minor | V-7 … V-19, G-2 … G-7, T-6 … T-10, D-1 |
| nit | V-20 … V-22, G-8, T-11, T-12, D-2 … D-4 |

---

## A. Vibe driver — `source/cydo/agent/drivers/vibe.d`

### V-1 · blocker · Startup failure leaks the `vibe-acp` process

- **Where:** `vibe.d:2316-2320` (`handleStartupFailure`), `vibe.d:2185-2209`
  (`stop`/`closeStdin` return early when `!alive_`), `vibe.d:435-438`
  (`VibeAcpProcess.shutdown` returns early when `dead`, which includes
  `State.failed`), `vibe.d:542-553` (`failStartup`). Failure call sites:
  `vibe.d:1696-1721` (session/load), `vibe.d:1728-1761` (session/new),
  `vibe.d:1619-1641` (effort option).
- **Problem:** On any startup failure, `VibeSession.handleStartupFailure` runs:
  `initialize` error, protocol mismatch, `session/new` error, `session/load`
  error such as a missing or deleted session, or a `set_config_option`
  rejection such as an invalid `effort`. It calls `handleExit(1)`, which sets
  `alive_ = false` and fires the exit callback. Nothing calls
  `server.shutdown()`. Any later `stop()` or `closeStdin()` returns
  immediately because `alive_` is already false. For an `initialize` failure,
  `VibeAcpProcess.state_` is `failed`, and `shutdown()` also returns early
  because `dead` counts `failed` as dead. The Python `vibe-acp` child keeps
  running with stdin open, and each retry or resume leaks another process.
- **Why it matters:** Resuming a task whose vibe session dir is gone, or
  configuring an unsupported `effort` value (V-14), will steadily accumulate
  orphaned ~100 MB Python processes. The unit tests cannot catch this because
  `TestVibeAcpProcess.shutdown()` (`vibe.d:568-579`) is overridden.
- **Fix:**
  1. In `VibeSession.handleStartupFailure`, call `server.shutdown()` after
     rejecting submissions, or have `attachSession`'s failure paths do it.
  2. Make `VibeAcpProcess.shutdown()` terminate the real process unless
     `process.dead`, so `State.failed` no longer short-circuits.
     Alternatively, call `process.terminate()` and `killAfterTimeout` from
     `failStartup`.
  3. Add a unit test asserting that a startup failure triggers shutdown, for
     example by recording shutdown calls in `TestVibeAcpProcess`.
  4. Note that `SdkProcess` (`source/cydo/agent/sdk.d:238,262-266`) has the
     same `dead`/`failed` early return. Check whether Copilot is affected,
     and if so fix it in a separate commit.

### V-2 · major · Per-task model selection is not honoured

- **Where:** `vibe.d:709-719` (`active_model` is written only if
  `config.toml` is absent), `vibe.d:688` (no model or env is passed to
  `vibe-acp`), `vibe.d:1619-1641` (only `thinking` is applied via
  `session/set_config_option`). Profile root resolution:
  `source/cydo/runtime/launch/environment.d:40-70`.
- **Problem:** The native-history profile root is `$VIBE_HOME`, or
  `$HOME/.vibe`, which is shared by all tasks. It is not per-task, even
  though the generated file's header says `# managed by CyDo — per-task
  agent profile`. `config.toml` is written once, with whichever model the
  first task resolved, and never updated. Every later task uses that model,
  whatever its `model_class` (`small`, `medium` or `large`) or configured
  `model_aliases`. If the user already has a `config.toml`, CyDo's model is
  never applied at all. The `session/init` event still reports the model
  CyDo intended (`vibe.d:1917`), so the UI shows a model that is not in use.
- **Why it matters:** Task-type model classes are silently broken for vibe.
  The e2e config (`flake.nix`, `active_model = "mock"`) hides this.
- **Fix:** Apply the model per session. `docs/research/vibe-acp-wire.md`
  (S8) documents a `model` config option on `session/new`. In
  `applyEffortOption`, or a new `applySessionOptions`, send
  `session/set_config_option {configId: "model", value: <model>}` before
  `thinking`. An alternative is to pass `VIBE_ACTIVE_MODEL` in the child env,
  which the one-shot path already relies on; this must survive the sandbox
  env. Then stop writing `active_model` to `config.toml`. Add unit coverage,
  and an e2e that asserts the model reaches the mock API (for example, the
  mock records the `model` field).

### V-3 · major · Driver writes into the user's real `~/.vibe`

- **Where:** `vibe.d:697-729` (`bootstrapVibeProfile`).
- **Problem:** The profile root defaults to the user's real `~/.vibe` (see
  V-2). On first CyDo use, the driver creates `config.toml` there (disabling
  telemetry and update checks and pinning `active_model`) and
  `trusted_folders.toml` (trusting one CyDo work dir). This silently changes
  the user's global Vibe configuration, including for their standalone
  `vibe` CLI use, and can pre-empt vibe's own first-run setup.
- **Fix:** Do not write into a profile CyDo does not own. Options:
  - Only bootstrap when the profile root is a CyDo-managed dir.
  - Pass the settings without touching files, via env or ACP config options.
  - Merge into existing files instead of create-if-absent, and only with
    explicit opt-in.
  - At minimum, fix the misleading "per-task" header comment and document
    the side effect in the README.

### V-4 · major (security) · One-shot runs `vibe --yolo` with tools enabled

- **Where:** `vibe.d:1536-1549` (`buildVibeOneShotArgs`), `vibe.d:1459-1533`.
- **Problem:** Titles and suggestions are generated from conversation
  content, which may include untrusted file or web text. They run
  `vibe --prompt … --max-turns 1 --yolo`, and `--yolo` auto-approves every
  tool call. `--max-turns 1` limits LLM turns, but tool calls emitted in that
  turn can still run. When `launch.cmdPrefix` is null (no sandbox), they run
  directly on the host. The Claude driver disables tools for the same
  purpose: `claude.d:863-873` passes `--tools ""` and
  `--no-session-persistence`. The plan (`vibe-support-implementation.md`
  §2.8) said to mirror the Claude shape.
- **Fix:** Run the one-shot with no tools, via whatever vibe offers to
  disable tools or select a no-tool or plan-only agent profile (verify the
  flag name in vibe 2.25.8, e.g. `--enabled-tools` or an agent profile). Drop
  `--yolo`. Add a unit assertion that `--yolo` is absent and the no-tools
  flag is present.

### V-5 · major · History replay emits `turn/result` mid-turn when a message has both text and tool calls

- **Where:** `vibe.d:1084-1139` (`translateHistoryLine`, `"assistant"` case).
- **Problem:** The comment says *"A plain-content assistant message
  terminates the turn"*, but the condition is only `ev.content.length > 0`.
  An assistant line with both `content` and `tool_calls` emits text,
  `tool_use` items, then `turn/stop` and `turn/result`. That second pair is
  synthesised before the tool results and before the real end of the turn.
  An example is "Let me check the file…" followed by a `bash` call, which is
  very common with Mistral models. The live path emits `turn/result` only on
  the `session/prompt` response, so reload no longer matches live rendering,
  and the reloaded transcript shows a premature result and split messages.
- **Fix:** Synthesise `turn/stop` + `turn/result` only when
  `content.length > 0 && no tool_calls`. When `tool_calls` are present, emit
  the per-segment `turn/stop` whether or not `content` is empty. Add a
  history unit test for the mixed case; the existing fixtures at
  `vibe.d:4247-4370` only cover text-only and tool_calls-only lines.

### V-6 · major (security hardening) · History image paths make the backend read arbitrary files

- **Where:** `vibe.d:1019-1037`.
- **Problem:** For each `images[].source.path` in a persisted user line, the
  backend calls `std.file.read(path)` and base64-encodes the result. The
  backend is unsandboxed and single-threaded. The profile dir is writable
  inside the agent sandbox (`materializeNativeHistoryProfile` requires
  `rw`), so a prompt-injected agent can append a crafted line to
  `messages.jsonl`. Such a line can:
  - point at any host file (for example `~/.ssh/id_rsa`), which then appears
    in the UI transcript, crossing the sandbox confidentiality boundary;
  - point at `/dev/zero`, causing unbounded memory use;
  - point at a FIFO, blocking the event loop forever.
- **Fix:**
  - Only read paths that resolve, after `realpath`, inside that session's dir
    or the profile root.
  - Require a regular file (`isFile`) and enforce a size cap.
  - Skip silently otherwise.
  - Add unit tests for each rejection case.

### V-7 · minor · `stopReason` is parsed but ignored, so cancelled or refused turns report success

- **Where:** `vibe.d:139-143` (`PromptResponse.stopReason`),
  `vibe.d:2591-2608` (`emitTurnResult`).
- **Problem:** The turn result is always `subtype: "success"`,
  `is_error: false`, with `result = lastResultText`. This applies to every
  stop reason: `cancelled` after an interrupt, `refusal`, `max_tokens` and
  `max_turn_requests`. Interrupted or refused partial output is delivered to
  parents as a successful sub-task result. Copilot does the same, but Codex
  distinguishes errors (`codex/package.d:4295-4302`).
- **Fix:** Map `cancelled` to an interrupted result (match how the other
  drivers surface interrupts), and `refusal`/`max_*` to `is_error: true` with
  a descriptive `result`. Add unit tests.

### V-8 · minor · Permission requests use a hard-coded `optionId` and bypass workspace `permission_policy`

- **Where:** `vibe.d:224-253`, `vibe.d:2288-2293`;
  `workflow/tools/backend.d:858` (policy is only evaluated for Claude's
  `--permission-prompt-tool`).
- **Problem:**
  - The driver always answers `optionId: "allow_once"` and never inspects the
    request's `options`. In ACP, `optionId` is agent-defined and `kind` is the
    stable field. It works for vibe 2.25.x (`vibe-acp-wire.md:124-134`), but
    breaks silently if the IDs change.
  - Every tool call is auto-approved, so a workspace
    `permission_policy: deny|ask|<expr>` is ignored for vibe. This is the
    same gap Copilot has, but ACP's `session/request_permission` is a natural
    hook for the policy.
- **Fix:**
  - Select the option whose `kind == "allow_once"`, falling back to
    `optionId == "allow_once"`. If neither exists, return `cancelled` and log.
  - Optionally route the request through `evaluatePermissionPolicy` and
    `promptUserForPermission`. If that is deferred, document in the README
    that vibe ignores `permission_policy`.

### V-9 · minor · Client fs capabilities are advertised but not implemented

- **Where:** `vibe.d:505-507` (`fs.readTextFile = true`,
  `fs.writeTextFile = true`) vs `IVibeAcpServer` (`vibe.d:276-285`), which
  has no `fs/read_text_file` or `fs/write_text_file` methods.
- **Problem:** The driver advertises capabilities it cannot serve. If a vibe
  version starts using client fs when advertised (ACP agents may), every
  file read or write gets method-not-found.
- **Fix:** Advertise `false` for both, matching what is actually implemented.
  Update `vibe-support-implementation.md` §2.6 accordingly.

### V-10 · minor · A missing user echo leaves a stale expectation, and the gated-echo code is dead

- **Where:** `vibe.d:2022` (expectation pushed), `vibe.d:2055-2058`
  (`accepted = true` before sending), `vibe.d:2359-2385`,
  `vibe.d:1966-1975`, `vibe.d:2075-2091`.
- **Problem:**
  - (a) If vibe never sends a `user_message_chunk` for a turn, the
    `ExpectedUserMessage` stays at index 0. This can happen with an empty
    text plus an image-only prompt, a version change, or vibe-side
    rejection. `finalizeTurn` never removes it, so the next turn's echo
    chunks accumulate against the stale entry, "diverge", and the UI shows
    the previous message's text for the new message.
  - (b) `submission.accepted` is always true before any chunk can arrive. So
    the `gatedUserEcho`/`hasGatedUserEcho` branch and `releaseGatedUserEcho`
    are unreachable.
- **Fix:** In `finalizeTurn`, drop any remaining expectation for
  `submission`. Remove the dead gating code, or document why it is kept. Add
  a unit test with a turn that has no echo, followed by a normal turn.

### V-11 · minor · `invalidatePendingSubmittedMessages` leaves `turnInProgress` set

- **Where:** `vibe.d:1977-1991`, `vibe.d:2158-2162`, `vibe.d:2077-2078`.
- **Problem:** The epoch bump drops the in-flight `session/prompt` response,
  but `turnInProgress` stays `true`, so a reused session would queue messages
  forever. Current callers (`workflow/tasks/mutations.d:525,596,1255`) kill or
  replace the session right after, so this is latent.
- **Fix:** Call `resetRejectedSubmission()` when voiding an in-flight turn.
  Alternatively, assert or document that the session must not be reused.

### V-12 · minor · `trusted_folders.toml` only ever trusts the first task's work dir

- **Where:** `vibe.d:721-728`.
- **Problem:** The file is create-if-absent and contains a single path.
  Worktree tasks and tasks in other projects get distinct work dirs that are
  never trusted. **Needs verification:** what vibe-acp does in untrusted dirs
  (for example, ignoring project-local `.vibe/` config or `AGENTS.md`).
- **Fix:** Pass trust through a non-file mechanism if vibe has one, or
  append the work dir if missing (merge, do not clobber). This is subject to
  V-3's ownership constraints.

### V-13 · minor · TOML values are not escaped

- **Where:** `vibe.d:717` (`active_model = "<model>"`), `vibe.d:727`
  (`trusted = ["<workDir>"]`).
- **Problem:** The values are spliced raw into TOML basic strings. A `"` or
  `\` in a path or model id produces invalid or misread TOML, and vibe fails
  to start or trusts the wrong path.
- **Fix:** Use TOML literal strings (`'…'`), rejecting values that contain
  `'`, or escape `\` and `"`. This is moot for `active_model` if V-2 removes
  it.

### V-14 · minor · Unsupported `effort` values fail startup and trigger V-1

- **Where:** `vibe.d:1619-1641`, `runtime/config/package.d:40`.
- **Problem:** `effort` passes through verbatim to vibe's `thinking` option
  (`off|low|medium|high|max`). Values valid for other drivers (for example
  `xhigh`) fail the session start, which leaks the process until V-1 is
  fixed. The behaviour is documented in the README, so this is acceptable
  once V-1 is fixed.
- **Fix:** Optionally validate against the `configOptions` returned by
  `session/new` and emit a clear task diagnostic.

### V-15 · minor · `historyPath` matches on the 8-character id prefix only and rescans every 2 s

- **Where:** `vibe.d:827-861`;
  `workflow/sessions/task_runner.d:457-467` (awaiting-path retries);
  `workflow/history/jsonl_tracker.d:100-107` (2 s retry timer).
- **Problem:**
  - The driver picks the lexically newest `session_*_<id8>` dir without
    checking that its `meta.json` `session_id` equals the full id. Before the
    new session's dir materialises, an older session with the same prefix
    could be attached as the live history.
  - Each retry scans all of `~/.vibe/logs/session`, which can be large.
- **Fix:** Verify `meta.json.session_id == sessionId`, which is already cheap
  via `readVibeMetaFile`. Consider caching the resolved dir once found;
  `registerHistoryPath` is currently a no-op.

### V-16 · minor · Fork destination metadata is inaccurate, and native fork is unused

- **Where:** `vibe.d:872-952`.
- **Problem:**
  - `Clock.currTime` (local time) is formatted with a `+00:00` suffix
    (`vibe.d:894, 930-932`), mislabelling the timezone.
  - `parent_session_id` is always `null`.
  - `total_messages` counts the source file, not the fork contents.
  - Hand-synthesising vibe's pydantic `SessionMetadata` is brittle across
    vibe versions. The wire doc shows vibe advertises
    `sessionCapabilities.fork` (`vibe-acp-wire.md`, S1).
  - Images in forked lines still reference the source session's attachment
    files.
- **Fix:**
  - Use `Clock.currTime(UTC())` for both the dir name and timestamps, after
    checking which zone vibe itself uses.
  - Set `parent_session_id` to the source id.
  - Evaluate ACP `session/fork` as the primary mechanism, keeping the
    synthesis as a fallback.

### V-17 · minor · needs verification · Fork/undo at a tool-calls-only assistant boundary may leave dangling tool calls

- **Where:** `vibe.d:1186-1222` (every non-injected assistant line is an
  `agent_turn` boundary).
- **Problem:** Cutting right after an assistant line with `tool_calls` but
  before its `role:"tool"` results produces a transcript that
  Mistral/OpenAI-style APIs reject, because tool calls lack responses.
  Claude has `repairInterruptedToolCall`, but vibe's returns `null`
  (`vibe.d:1224-1230`). Its comment claims nothing is persisted for an
  interrupted call, but T-2 shows vibe does persist a cancellation `role:"tool"`
  record.
- **Fix:** Verify how vibe and the API handle it on `session/load` plus the
  next prompt. If it fails, either only emit `agent_turn` boundaries for
  turn-terminal assistant lines, or synthesise tool results when cutting.

### V-18 · minor · One-shot env lacks `MISTRAL_API_KEY`, `VIBE_HOME` and proxies when unsandboxed

- **Where:** `vibe.d:1471-1489`.
- **Problem:** With `cmdPrefix is null`, the child gets only `PATH` and
  `HOME` (plus `VIBE_ACTIVE_MODEL`).
  - Users who provide `MISTRAL_API_KEY` via the environment rather than
    `~/.vibe/.env` will see title and suggestion generation fail.
  - A configured `VIBE_HOME` is ignored, so the one-shot uses `~/.vibe`
    config.
  - `HTTPS_PROXY` is dropped.

  The interactive path passes these through (`configureSandbox`,
  `vibe.d:640-644`).
- **Fix:** Add the same passthrough keys to the minimal env. Add a unit test
  for the env map, factoring env construction into a pure function like
  `buildVibeOneShotArgs`.

### V-19 · minor · needs verification · One-shot runs may persist sessions that then show up in discovery

- **Where:** `vibe.d:1346-1389` (`enumerateAllSessions`), `vibe.d:1536-1549`.
- **Problem:** Claude passes `--no-session-persistence`. If `vibe --prompt`
  writes `logs/session/session_*` dirs, every title or suggestion call
  creates a discoverable "session" in CyDo's import list and the user's
  vibe history.
- **Fix:** Verify. If sessions are persisted, disable session logging for
  one-shots (config or env override), or filter them out on enumeration.

### V-20 · nit · `bootstrapVibeProfile` resolves the model twice

- **Where:** `vibe.d:715`. The caller already resolves the class at
  `workflow/sessions/task_runner.d:608-609`.
- **Problem:** `config.model` is already a concrete model id, so
  `resolveModelSpec(config.model)` is redundant. It would mis-map a model
  literally named `small`, `medium` or `large`. The unit test at
  `vibe.d:3230` passes a class name, which does not reflect production.
  This is moot if V-2 removes `active_model`.

### V-21 · nit · `VibeAcpProcess` duplicates `SdkProcess` almost verbatim

- **Where:** `vibe.d:314-554` vs `source/cydo/agent/sdk.d:183-365`.
- **Problem:** The shutdown, readiness queue, `failStartup` and router
  pattern are duplicated, differing only in framing and `pendingSession`.
  Fixes such as V-1 now need to be made twice.
- **Fix:** Consider a shared JSON-RPC subprocess base parameterised on
  framing and handler type in a follow-up refactor. This is not required for
  merge.

### V-22 · nit · Typos and comments

- `vibe.d:1484`: "Unsanboxed" / "Sanboxed" should be "Unsandboxed" /
  "Sandboxed".
- `vibe.d:712`: the "per-task agent profile" header is incorrect (see V-2
  and V-3).
- `vibe.d:3029`: the comment says "inert in Part 2", which is
  plan-phase wording that will rot.

---

## B. Generic / core changes

### G-1 · major · keep_context reframe can corrupt history and writes non-atomically

- **Where:** `source/cydo/server/app.d:2547-2610`
  (`reframePersistedSessionStart`), `app.d:2616-2657`
  (`reframeSessionStartLine`).
- **Problems:**
  1. `readText(path).lineSplitter` splits on more than `\n`. Per the Phobos
     docs, `lineSplitter` also breaks on `\r`, `\v`, `\f`, U+0085, U+2028 and
     U+2029. JSON permits raw U+0085, U+2028 and U+2029 inside strings. The
     loop then rejoins every fragment with `"\n"`, so any message containing
     one of those characters is split into two invalid JSON lines and the
     history is corrupted. Whether vibe writes them raw depends on its
     serializer: pydantic `model_dump_json` and `json.dumps` with
     `ensure_ascii=False` both do. This **needs verification**, but splitting
     on `'\n'` only is safe regardless.
  2. `write(path, rewritten)` is not atomic. A crash or full disk
     mid-write truncates the session history.
  3. The rewritten line is re-serialized with `std.json`. `JSONValue` objects
     are AA-backed, so key order is not preserved and number formatting may
     change. This is probably harmless to vibe, but it is an unnecessary
     whole-line rewrite.
  4. The whole file is always rewritten, even when only line 1 changes.
- **Fix:**
  - Split with `splitter('\n')` (or `byLine` semantics) and preserve the
    original trailing-newline state.
  - Write to `path ~ ".tmp"`, `fsync` it, then `rename`.
  - Optionally splice only the `content` value.
  - Add a unit test with a U+2028 inside a message and confirm it
    round-trips.

### G-2 · minor · Reframe is gated on `!supportsDeveloperPrompt`, which also matches Codex

- **Where:** `app.d:2552`; `codex/package.d:1022` returns `false`.
- **Problem:** Codex tasks now enter `reframePersistedSessionStart` on every
  keep_context switch. Codex rollout lines have no top-level `role`, so the
  call reads the whole rollout and does nothing. The doc comment at
  `app.d:2542-2546` says the feature targets "the others (vibe)", but Codex
  has the same stale-framing problem and it remains unaddressed.
- **Fix:** Gate explicitly, either on a new agent capability (e.g.
  `rewritesPersistedFraming`) or on the driver. Either implement Codex too, or
  document that it is out of scope.

### G-3 · minor · Reframe only fixes the first message

- **Where:** `app.d:2586-2599`; continuation framing at
  `workflow/tools/backend.d:1488-1492`.
- **Problem:** After two or more keep_context switches (A→B→C), the A→B
  mode-switch message still carries B's full framing, because every
  mode-switch message prepends framing for agents without a developer
  prompt. The intent "old mode's instructions would no longer ride along" is
  only met for one switch. Each switch also duplicates the new framing, once
  in the reframed session start and once in the mode-switch message.
- **Fix:** Decide the intended semantics and document them. Either also strip
  framing from earlier mode-switch messages, or stop re-prepending framing in
  the mode-switch message once the session-start line carries it. Add an e2e
  for a double switch.

### G-4 · minor · `operations.d` drops `final switch` exhaustiveness for `CodexForkSourceState`

- **Where:** `source/cydo/workflow/history/operations.d:55-58`.
- **Problem:** `final switch (codexForkSource)` became `switch` with
  `default: break;` for no functional reason. A new `CodexForkSourceState`
  member would now silently yield "no operations" instead of a compile
  error.
- **Fix:** Restore `final switch` and remove `default`.

### G-5 · minor · Batch delivery gives up silently after one retry

- **Where:** `source/cydo/workflow/tasks/subtask_delivery.d:287-311`.
- **Problem:** Bounding the hot loop is correct. However, when the retry also
  finds no sendable session, it only `warningf`s and resolves, so child
  results are never delivered. Delivery recovers only if the user manually
  resumes the task (`app.d:1806-1812` → `deliverBatchFallbackIfReady`). This
  is a driver-agnostic behaviour change made inside a `fix(vibe)` commit,
  with no test.
- **Fix:** Surface a task diagnostic via the existing
  `appendAndBroadcastRecoveryDeliveryDiagnostic` host hook so the user knows
  to resume. Add a unit test for both give-up branches: shutting down, and
  retried. Consider splitting it into its own `fix(delivery)` commit.

### G-6 · minor · `handleResumeMsg` alive-branch diverges from `clearAttention` semantics

- **Where:** `app.d:1794-1806`; `domain/tasks/lifecycle.d:72-75`.
- **Problem:** The new `else` branch clears `needsAttention` but not
  `notificationBody`, whereas `TaskNotificationChange.clearAttention` clears
  both. It also changes resume behaviour for all drivers (resuming an
  `alive` task with no running process) without a dedicated test or commit.
- **Fix:** Also clear `td.notificationBody`, or factor a shared
  "clear attention" helper out of `lifecycle.d`. Add an e2e or unit test,
  and consider a separate commit.

### G-7 · minor · `jsonl_tracker` now silently drops boundary candidates for every driver

- **Where:** `source/cydo/workflow/history/jsonl_tracker.d:129-135`.
- **Problem:** The code previously relied on `requireLiveContext`, which
  enforces the invariant. Now any task without a live context skips
  silently, which could mask a regression in the Claude or Codex lifecycle.
  The `boundaryState[tid]` entry is also created before the early return.
- **Fix:** Move the early return above the `boundaryState` initialisation.
  Add a `tracef` when skipping. Consider limiting the skip to the
  awaiting-path state rather than "no context at all".

### G-8 · nit · Mixed concerns in the `task_runner` comment

- **Where:** `workflow/sessions/task_runner.d:459-466`.
- **Problem:** The comment states that "a genuinely empty path from a bound
  driver would make every retry re-scan harmlessly", but those retries
  continue every 2 s for the life of the session (see V-15). Reword it, or
  bound the retries.

---

## C. Tests, mock API, Nix

The final tree has no `test.skip`, `test.fixme` or `@no-vibe` tags. The vibe
project runs the real `vibe-acp` and `vibe` binaries against the mock LLM,
which is consistent with AGENTS.md. The four `flake.nix` hashes match the
upstream v2.25.8 release digests, and the upstream license is Apache-2.0.

### T-1 · blocker (policy) · The merge commit was made with `--no-verify`

- **Where:** commit `98a9477` ("Merge branch 'master' into
  feature/add_mistral_cli"). Its message says *"the pre-commit hook rejects
  on it, so this merge is committed with --no-verify; the gate stays red"*.
- **Problem:** AGENTS.md bans `--no-verify`, and work is not complete until
  `nix flake check` passes. The author attributes the failing cell
  (`e2e-claude-semantic-shell-L251`) to a pre-existing master regression.
  However, the branch's whitespace churn (T-7) renumbers that cell, since it
  is L249 on master, so the claim cannot be checked directly.
- **Fix:**
  - Revert the T-7 churn.
  - Confirm the failure on clean `master` under its master cell name.
  - Get it fixed on master, or cherry-pick the fix.
  - Re-create the merge, or rebase, with the hook passing.
  - Do not merge with a red gate.

### T-2 · major · The vibe continuation assertion is weaker than claude/codex, and its context check is vacuous

- **Where:** `tests/e2e/continuation.spec.ts:231-232`, `245-285`
  (`assertVibeContinuationResult`), `317-327`.
- **Problem:**
  - Claude and Codex must persist the repaired success text. Vibe accepts
    either the success prefix **or** `"interrupted by user"`, which is
    exactly the stale-cancellation state the other drivers' repair exists to
    remove. A resumed vibe context therefore shows the model its successful
    SwitchMode as cancelled by the user.
  - The follow-up `check context contains` needle at L318-321 is
    `"aborted by user after"` for every non-claude agent. That is Codex's
    marker and can never appear in vibe history, so the vibe
    `context-check-failed` assertion passes regardless.
  - The driver comment (`vibe.d:1224-1230`, "an interrupted call leaves no
    partial record to repair") contradicts the test, which shows a
    cancellation record is persisted.
- **Fix:**
  - Implement `repairInterruptedToolCall` for vibe, rewriting the cancelled
    `role:"tool"` line to the accepted text, and assert the success text as
    the other agents do.
  - Use a vibe-specific needle such as `interrupted by user` or
    `<user_cancellation>`.
  - Correct the driver comment. This interacts with V-17.

### T-3 · major · The shared `system-messages.spec.ts` test was rewritten for all agents and covers less

- **Where:** `tests/e2e/system-messages.spec.ts:93-168` ("task prompt system
  message keeps task type label after reload").
- **Problem:**
  - The original clicked the child's sidebar item and asserted the live
    in-page "Task prompt: research" message, then asserted again after
    reload. The rewrite only uses `page.goto('/local/cydo-test-workspace/task/<tid>')`
    inside `toPass` retry loops, so both checks are fresh page loads. The
    live-streamed path and the real click navigation are no longer tested
    for any agent.
  - The comment says the test waits for the parent's turn to end, but
    `expect(input).toBeEnabled()` (L149) does not do that, because the input
    stays enabled while processing.
  - The retry loop papers over a late `focus_hint` race instead of fixing or
    asserting it.
  - It adds explicit `10_000` and `120_000` timeouts, against the
    `playwright.config.ts:5-13` policy.
  - It hard-codes the workspace slug.
- **Fix:**
  - Restore the click-based live and post-reload assertions.
  - Add a deterministic wait: the parent sidebar item is active and the
    parent's final assistant text is visible (pattern at
    `ask-answer.spec.ts:1566-1570`).
  - If the late `focus_hint` is a real backend or UX bug, file it separately
    instead of retrying around it.

### T-4 · major · The mock's unsupported-intent fallback answers "Done.", so tests pass without testing anything

- **Where:** `tests/mock-api/server.mjs:1619-1623`.
- **Problem:** Unimplemented fixture intents reply
  `Done. (unsupported intent X)`. `Done.` is the suite's universal success
  sentinel, and `assistantText` is a substring match, so a spec can pass
  without its fixture ever running. One concrete case is
  `tests/e2e/session-ending.spec.ts:101` ("background command output
  re-enters processing state", runs on vibe). It uses `timed_shell`, which
  the chat dialect does not implement, so vibe never runs the background
  command. Why the final assertion still passes **needs verification**.
- **Fix:**
  - Make the fallback fail loudly: HTTP 500, or text without `Done.`, such as
    `MOCK-UNSUPPORTED-INTENT:<type>`.
  - Either implement `timed_shell` in the chat dialect, or tag
    session-ending L101 with a documented reason.
  - Re-run the vibe matrix to find any other false greens.

### T-5 · major (flakiness) · Known vibe resume-after-kill race left untracked

- **Where:** `docs/plans/vibe-support-session-state.md:63-66, 311-312`
  (`session/load` intermittently failing with `-31002 "'role'"` on a killed
  session's log, "still uninvestigated upstream"). Commits `c7a6c54` and
  `a263130` untagged the kill/resume specs because it "does not reproduce".
- **Problem:** The config sets `retries: 0` ("flaky tests are bugs"). The
  affected specs are history-survives-reload, no-duplicates-after-reload,
  session-resume, and send-to-stopped-session-auto-resumes.
- **Fix:**
  - Root-cause the race. One likely cause is a truncated trailing line in
    `messages.jsonl` after SIGKILL. The driver could trim an unparsable last
    line before `session/load`, or CyDo's history reader could tolerate it.
  - Run `--repeat-each=20..50` on those cells before merge.
  - This also bears on V-1, since the failed load currently leaks the
    process.

### T-6 · minor · The synthesised fork destination is never loaded by real vibe in e2e

- **Where:** `tests/e2e/history-fork-boundaries.spec.ts:148, 182, 225` and
  `ui-regression.spec.ts:~163-167`.
- **Problem:** The "resume the forked child and check its context" steps are
  gated on `agentType === "claude"`. The hand-built `meta.json` from V-16 is
  therefore only validated against UI replay, never against vibe's
  `session/load`.
- **Fix:** Enable the resume and context-check block for vibe. The chat
  dialect already supports `check_context`.

### T-7 · minor · Whitespace-only churn in 27 spec files renames check derivations

- **Where:** 27 of the 32 changed files under `tests/e2e/`, for example
  `undo.spec.ts`, `fd-leak.spec.ts` and `auto-suggest.spec.ts`. The changes
  are `test("title",\n    async ({` splits and `tag: "@x"` →
  `tag: ["@x"]`. They look like leftovers from adding and then removing
  `@no-vibe` tags.
- **Problem:** `flake.nix` bakes line numbers into check names
  (`e2e-<agent>-<spec>-L<line>`). Dozens of tests per agent are renumbered,
  which forces rebuilds, widens the merge-conflict surface, and obscures
  T-1.
- **Fix:**
  - Run `git checkout master -- <those files>`. The semantic changes are only
    in `continuation.spec.ts`, `fixtures.ts`, `image-paste.spec.ts`,
    `system-messages.spec.ts`, and the new `vibe-basic-flow.spec.ts`.
  - Fix the mis-indented `);` at `continuation.spec.ts:240-243`.

### T-8 · minor · The mock chat-completions stream diverges from the real wire format and duplicates `copilot-proxy.mjs`

- **Where:** `tests/mock-api/server.mjs:1459-1623`;
  `tests/mock-api/copilot-proxy.mjs:97-272` already implements the same
  OpenAI chat SSE.
- **Problem:**
  - Every chunk gets a fresh id.
  - The full tool call and `finish_reason` arrive in one chunk, so the
    incremental argument accumulation vibe's SDK performs is never exercised.
  - `parsed.stream` is ignored, so non-streaming requests would get SSE.
  - There is no error injection.
  - Tool-result detection only checks the last message's role.
  - The `cydo_` name mapping is copy-pasted three times.
  - `held_title` duplicates `text`.
  - `background_shell` is mapped to a synchronous `bash` call.
  - A `multi_tool_call` second call named `Bash` is not mapped to vibe's
    `bash`, so `ask-answer.spec.ts:1534` cannot test its post-answer
    ordering on vibe (**needs verification**).
- **Fix:**
  - Extract a shared chat-chunk emitter used by both mocks: one id per
    completion, a header chunk, argument-delta chunks, a separate finish
    chunk and an optional usage chunk.
  - Map tool names through one helper.
  - Return an OpenAI-shaped error object.

### T-9 · minor · Test config pre-seeds vibe's profile, so production bootstrap and model paths are untested

- **Where:** `flake.nix:851-879`.
- **Problem:** `config.toml` and `trusted_folders.toml` are pre-written, so
  `bootstrapVibeProfile` never runs in e2e. The config sets
  `active_model = "mock"` (hiding V-2), `thinking = "off"` (hiding the
  effort default), and `[tools.bash] permission = "always"` (hiding the ACP
  permission flow). The provider is a `generic` OpenAI-style backend, so the
  stock Mistral backend path is not covered.
- **Fix:**
  - Add a cell with an empty `VIBE_HOME` to exercise the bootstrap, or the
    replacement mechanism from V-2 and V-3.
  - Add an assertion that the mock receives the CyDo-selected model id.
  - Document that the real Mistral backend is out of e2e scope.

### T-10 · minor · `vibe-basic-flow.spec.ts` smoke specs are now mostly redundant

- **Where:** `tests/e2e/vibe-basic-flow.spec.ts`.
- **Problem:** These were added while most of the suite was excluded for
  vibe. Two duplicate `basic-flow.spec.ts`, which now runs on vibe. Each is
  an extra nix derivation.
- **Fix:** Keep only the stop-via-`session/cancel` case and drop the rest.

### T-11 · nit · Packaging (`flake.nix`)

- The comment at L225 ("PyInstaller binaries are pre-stripped; patching may
  corrupt them") sits above `dontStrip = true` while `autoPatchelfHook` is
  active. The comment contradicts the code; reword it.
- Add an `installCheckPhase` (e.g. `$out/bin/vibe --version`) so a damaged
  PyInstaller archive fails once at package build instead of in roughly 180
  e2e derivations.
- `libgcc.lib` and `stdenv.cc.cc.lib` overlap in `buildInputs`.
- `meta.license`, `mainProgram`, `sourceProvenance` and `updateScript` are
  missing, as they are for codex and copilot.

### T-12 · nit · Guardrails

- `image-paste.spec.ts:31-33` correctly notes that `flake.nix` only flattens
  top-level `suite.specs`, so `describe`-wrapped tests silently never ran in
  `nix flake check`. Add an eval-time assertion that rejects nested suites.
- No spec reloads after an image prompt, although `d4c0efa` added history
  image inlining. Add one, which also covers V-6's happy path.
- `image-paste.spec.ts:75` (test 2) changed from `@claude-only` to untagged,
  so it now also runs on codex and copilot. Confirm that is intended.

---

## D. Docs and process

### D-1 · minor · Planning and session-state docs are agent working notes

- **Where:** `docs/plans/mistral-vibe-support.md`,
  `docs/plans/vibe-support-implementation.md`,
  `docs/plans/vibe-support-session-state.md` (about 1200 lines in total).
- **Problem:** They contain per-session logs ("What was completed this
  session"), commit hashes that change on rebase or squash, superseded
  "deferred" lists, and gate transcripts. Some statements are now stale. For
  example, §2.8 says "Mirror the Claude one-shot shape", which the
  implementation did not do (V-4).
- **Fix:** Before merge, condense them into one design note. Keep the wire
  findings (`docs/research/vibe-acp-wire.md`) and drop the session-state
  log, or move it out of the tree.

### D-2 · nit · Third-party spec copies

- **Where:** `docs/research/acp/SPEC_v1.md`, `SPEC_v2.md`.
- **Problem:** These are derived from the Apache-2.0 ACP repository. The
  header names the license, but there is no NOTICE or attribution beyond
  that. `SPEC_v2.md` is an unstable draft that the driver does not use.
- **Fix:** Keep the attribution, or link upstream instead. Consider dropping
  `SPEC_v2.md`.

### D-3 · nit · Commit messages and commit scope don't follow AGENTS.md

- Non-conventional subjects:
  - `215d41a Initial analysis and implementation plan for mistral-vibe`
  - `21bc63b Add vibe acp wire protocol doc`
- Mixed scope, against AGENTS.md's "split unrelated changes":
  - `d87c294` is typed `test(e2e)` but includes a `vibe.d` driver fix and
    the shared `system-messages` rewrite.
  - `3c76870` is `fix(vibe)` but changes driver-agnostic batch delivery
    (G-5).
  - `e432593` bundles a feature with untagging 23 specs.
- **Fix:** Use `docs(vibe): …` if history is rewritten before merge, e.g. on
  a squash.

### D-4 · nit · README limitations

- **Problem:** The README marks vibe "💥 Experimental" but does not list its
  known gaps:
  - no file revert;
  - workspace `permission_policy` is ignored (V-8);
  - no dedicated renderers for vibe's `read_file`, `write_file`,
    `search_replace` and `grep` tools (`web/src/components/ToolCall.tsx` only
    maps `vibe/bash`);
  - `effort` must be one of `off`, `low`, `medium`, `high` or `max`.
- **Fix:** Add a short limitations note.

---

## E. Things verified as intentional or OK (do not "fix")

- Auto-approving ACP permissions and reporting
  `permission_mode = "dangerously-skip-permissions"` matches the Copilot
  driver (`copilot.d:1456-1459`). See V-8 only for robustness and policy
  parity.
- `closeStdin()` sending `session/cancel` before shutdown mirrors Copilot's
  `session.abort` (`copilot.d:1321-1337`).
- Accepting a submission when `session/prompt` is sent (`vibe.d:2047-2058`)
  is deliberate and well justified in the comment: task status flips to
  `active` mid-turn.
- Replay suppression during `session/load`: persisted `messages.jsonl` is the
  transcript source. This is consistent with the history translation and
  unit-tested (`vibe.d:3817`).
- The keep_context reframe runs only after the agent process has exited.
  Continuations are spawned from the clean-exit path
  (`task_runner.d:1130-1133`), so the vibe process is not concurrently
  writing the file.
- `selectHistoryOperations` giving vibe jsonl fork/undo is consistent with
  `createHistoryForkDestination` plus in-place truncation, and is
  unit-tested.
- `awaitingPath` for an empty `historyPath` mirrors the existing Codex
  `liveSessionPath` handling (`task_runner.d:448-455`).
