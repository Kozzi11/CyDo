# Vibe Support — Session State (updated 2026-09-21, afternoon)

Companion to `docs/plans/vibe-support-implementation.md`. The work below
landed in commit `a786a82` (`test(e2e): add vibe project with smoke
coverage and prune long-tail`) on `feature/add_mistral_cli`. Prior
commits: `6dc95d1` (registration), `1d256f7` (driver), `e0c45e0` (nix
packaging). The "What was completed" and "Bugs found" sections are kept
as the record of how the state below was reached.

## What was completed this session

### Part 3 — E2E infrastructure (from the plan)
1. **Mock server** (`tests/mock-api/server.mjs`): added
   `POST /v1/chat/completions` handler for vibe's generic OpenAI-compatible
   backend. Maps shared `matchPattern` intents to chat-completions SSE:
   `text`→content, `shell`→`bash` tool call, `tool_call`/`multi_tool_call`
   with `mcp__cydo__X` → `cydo_X` naming, tool-result follow-ups → "Done.",
   `stall` → open stream. **Critical detail: tool_calls entries need
   `index: 0`** (vibe rejects chunks without it: "Tool call chunk missing
   index").
2. **flake.nix**: `vibe` project in `projectConfig` (extraNativeBuildInputs
   `[ mistral-vibe ]`), `knownAgents += "vibe"`, buildPhase writes
   `/tmp/vibe-test-home/config.toml` (mock provider, `active_model = "mock"`,
   `[tools.bash] permission = "always"`), trusted_folders.toml, and symlinks
   vibe-acp/vibe into `/tmp/fake-bin`. Also `mistral-vibe` added to the
   checks-let bindings.
3. **playwright.config.ts**: `vibe` project; **fixtures.ts**: AgentType
   union + validation + `historyPathForTask` vibe case (scan
   `/tmp/vibe-test-home/logs/session/*/messages.jsonl` by first-8 of
   session id).
4. **agent-sandbox-env.yaml**: `MISTRAL_API_KEY`, `VIBE_HOME` env entries.
5. **tests/e2e/vibe-basic-flow.spec.ts** (new, `@vibe-only`): text reply,
   bash tool round-trip, stop-aborts-stalled-session. All 3 pass.

### Bugs found & fixed (all e2e-caught, in `vibe.d` unless noted)
- **Null env value in session/new**: vibe's SDK (2.25.4 pydantic) rejects
  `value: null` — omit `CYDO_HANDOFFS` when null instead of serializing it.
- **Permission response shape**: must be nested
  `{"outcome":{"outcome":"selected","optionId":"allow_once"}}`, not flat.
  Fixed `PermissionOutcome`/`PermissionOption` structs + unit test.
- **Leaked promise on live-history watch**: `task_runner.d`
  `resolveLiveHistoryWatch` → treat empty `historyPath` as `noLiveBinding`
  (was: rejected promise poisoned the event loop).
- **jsonl_tracker assert**: `noteLiveBoundaryCandidate` → skip when no live
  context attached (was: assert crash `jsonl_tracker.d(74)`).
- **history operations**: `operations.d` — vibe returns empty fork/undo
  mechanisms (jsonl machinery not wired for vibe yet).
- **vibe historyPath implemented** (`vibe.d`): scans
  `$VIBE_HOME/logs/session/session_<ts>_<id8>/messages.jsonl` by first-8 of
  session id, newest dir wins; + unit test. This fixed transcript loss on
  session exit (was: history unavailable → `task_reload` wiped UI messages).
- **Frontend** (`web/src/components/ToolCall.tsx`): added `vibe/bash` to
  `isShellTool`, `defaultExpandedTools`, `defaultExpandedResults` sets.
- **Spec tool-name assertions**: basic-flow / diff-result-toggle /
  semantic-shell / ui-regression now pick `bash` (lowercase) for vibe.

### Test pruning (88 → 0 failing vibe checks)
88 long-tail tests fail on vibe — dominated by MCP tool dialect gaps (Ask/
AskUserQuestion/SwitchMode/web_search/task-spawn fixtures are written in
Anthropic/Codex tool dialects; vibe's chat-completions dialect only covers
text/bash/cydo_* basics). Tagged those tests `@no-vibe` (32 spec files,
tags-only diff, no formatting churn). Two more tagged for a **vibe 2.25.4
killed-session race**: `session/lifecycle` resume-after-kill tests
(`session/load` intermittently fails with `-31002 "'role'"` on the log of a
killed session). Also: prettier reformatted test-name/`toolName` ternaries
in 4 spec files.

## Current verification status (updated this session)
- **The three "non-vibe failures" from the last full flake check were
  artifacts of a mid-session state where `@no-codex`/`@no-copilot` tags
  had been dropped** from `system-prompt-switch.spec.ts` and
  `project-memory.spec.ts` (the flake-check snapshot `p43j7wlg` shows
  only `@no-vibe`). Those tests are known-broken on codex/copilot — that
  is why they carry the tags. The r11/r12/r13 retries of
  `e2e-codex-system-prompt-switch-L36` failed for this reason; with the
  tags restored the drv does not even exist for codex. No real
  regression; nothing to fix in `copilot.d`.
- **The pre-commit hook gates the committed tree, not the dirty tree.**
  Nix's dirty-tree eval excludes untracked files, so a dirty-tree
  `nix flake check` (with `vibe-basic-flow.spec.ts` untracked) builds a
  different drv family than the commit the hook evaluates — the morning
  `flake-check-v2.log` run (768 builds, green) covered the tree *minus*
  the new spec. Before committing, the committed-tree checks were built
  directly (`nix build --keep-going` over all 779
  `checks.x86_64-linux` drvs of the index tree): **green**, including
  all vibe checks and the three `vibe-basic-flow` specs. The pre-commit
  hook then passed for the commit itself.
- **The implementation plan's 6-commit split is not gateable**: any
  intermediate tree has the vibe project active (flake.nix committed at
  `e0c45e0`) without the mock dialect / tag pruning / driver fixes, so
  its vibe e2e checks fail. The code+tests changes are effectively
  atomic under this repo's gate and landed as one commit.
- `packages.x86_64-linux.screenshots` eval error
  (`git+file:docs/tools/screenshots/fixtures`, a gitlink without a
  .gitmodules mapping) is environmental, fails on a clean tree too, and
  makes dirty-tree `nix flake check` exit non-zero regardless.

## Leftover local-debug processes/files (safe to clean)
- Local mock on :9999 (`/tmp/vibe-probe-mock.mjs`), probe homes
  (`/tmp/vibe-probe-home*`, `/tmp/vibe-bwrap-probe-home`), probe scripts
  (`/tmp/vibe-bwrap-probe*.mjs`, `/tmp/local-ws.mjs`), logs (`/tmp/vibe-*.log`,
  `/tmp/r*.log`, `/tmp/flake-check*.log`, `/tmp/retry*.log`), and a local
  backend config at `/home/kozak/.config/cydo/config.yaml` (points at
  /tmp/local-ws workspace — remove or restore your own).
- `example.yaml` untracked at repo root — pre-existing, not mine.
- A `result` symlink in repo root may point at `fake-bwrap` (from probe) —
  `rm result` if in the way.

## Next steps (in order)
0. Done this session: **bumped mistral-vibe to v2.25.7** (flake.nix
   hashes for all four assets). Release-notes review: 2.25.7 is
   teleport/config/UI fixes; 2.25.5 (skipped) switched the default to
   the Unified Harness and made MCP tool calls go through the
   permission system by default — both re-verified green: all 117
   vibe e2e checks pass against 2.25.7 (the driver's auto-approve
   handles any new cydo_* permission requests). Driver comments now
   cite the verified range 2.25.4–2.25.7.
1. Done this session (afternoon): Part 4 history parsing —
   `translateHistoryLine` (persisted LLM-message lines → agnostic items,
   turn synthesis), `extractPersistedHistoryBoundaries` (message_id
   anchors, line:<n> fallback), `enumerateAllSessions`/`readSessionMeta`/
   `matchProject` (session dirs + meta.json, full resumable session ids),
   effort→thinking mapping via `session/set_config_option`
   (`driverSupportsEffort(vibe)` flipped to true), plus the README agent
   table row. In-file unit tests cover all of it.
2. Also fixed this session (found via the gate):
   - **Vibe tasks persisted status "active" after every turn.** Root
     cause: ae promises defer `.then` handlers (`callSoon` = next tick),
     and vibe's submission acceptance coincided with the session/prompt
     *response* (turn END). Fix (redesigned after the first attempt):
     the driver now fulfills the submission promise when the
     session/prompt REQUEST is written — the same point the other
     drivers accept (claude's stdin write). Mid-turn the task is
     "active" as the question router and restart machinery expect;
     at turn end the turn result idles it with no deferred
     acceptance to re-activate it. A failed session/prompt response
     surfaces as process/stderr plus an errored turn/result (the
     session survives); voided submissions (exit/invalidate) drop
     their late responses via a submission epoch counter. This also
     restores the user-message-before-assistant DOM order —
     history-order L29 is untagged. Verified end-to-end with an
     isolated local backend: status trajectory ends alive; the
     restarted backend logs `status=alive` and takes the no-nudge
     resume path.
   - **CyDo MCP tool results were invisible to the frontend**: vibe
     nests the structured payload ({tasks:[...]} for Task,
     {status, qid, ...} for Ask/Answer) under rawOutput's
     `structured` field; item/result now unwraps it into
     `tool_result` (live and history reload paths) so the frontend's
     subtask-result renderer sees the same shape the other drivers
     deliver. This unblocked the first ask-answer specs for vibe.
     Likewise, vibe wraps the real textual outcome (including tool
     errors like "Unknown question ID") in rawOutput's `text` while
     the content array only carries a "Ran <Tool>" presentation —
     extractToolResultText now prefers the wrapper text, which made
     the four ask-answer error-visibility specs pass.
   - **Vibe's live history watch never attached when the session dir
     did not exist at session start** (vibe materializes it on the
     first prompt): resolveLiveHistoryWatch now returns awaitingPath
     instead of noLiveBinding for a bound driver with an unresolvable
     path, so the watch attaches (with retry) and the exit-path
     reconcile always finds a live context — session-ending L37
     crashed with "requires an attached live history context" before
     this.
   - **Batch-result delivery could hot-spin the event loop forever.**
     `actuallyDeliverBatchResults` re-entered `deliverBatchResults` via a
     next-tick requeue whenever the parent's session was not sendable —
     with no shutdown check, no cap and no delay. At backend shutdown
     (four concurrent vibe sessions, parent cancelled) this spun
     millions of retries per minute and wedged the process until
     SIGKILL (ask-answer L1379). The delivery now gives up once the
     shutdown has begun (new `shuttingDown` hook on the delivery host)
     and after one failed resume attempt.
   - **Vibe's chat client rejects parallel tool calls with different
     names in one assistant message** ("Can't accumulate messages with
     different tool call names", 2.25.4). The mock's chat dialect now
     decomposes multi_tool_call fixtures: only the first call is
     emitted, and each tool result advances to the next call
     (`nextPendingToolCall` re-matches the turn-opening user text).
     This made the deferred-answer spec pass (ask-answer L1534) and the
     whole ask-answer spec now runs for vibe.
   - `handleResumeMsg` could not resume a task whose status was already
     "alive" — its `transitionTask` expectedFrom list excludes alive, and
     alive→alive is not a legal transition, so the resume crashed the
     backend ("Task transition origin mismatch"). Masked before by the
     stale "active" status; the fix skips the no-op transition (clears
     attention + broadcasts instead). continuation.spec L328 pinned it.
   - `CYDO_CREATABLE_TYPES`/`CYDO_SWITCHMODES` null values are omitted
     from the session/new MCP env (pydantic rejects null; the earlier
     fix only covered CYDO_HANDOFFS — a latent bug whenever no task-type
     context exists).
   - session/load replay content (user/agent chunks, tool calls) is now
     consumed silently — the persisted messages.jsonl is the transcript
     source of truth, so replaying it after a history load would
     duplicate every message. The compaction boundary pair is the one
     replay event still emitted.
3. Still deferred:
   - Vibe dialect fixtures for the remaining `@no-vibe`-tagged specs. The
     chat-completions dialect maps text/shell/tool_call/multi_tool_call/
     stall and answers every tool result with "Done." — the Ask/AskUser/
     SwitchMode/task-spawn families need tool-result-aware second
     responses (mirror the Anthropic handler's `findOriginalUserText`
     sequences in `handleChatCompletions`).
   - `history-order.spec L29` (user message above assistant in DOM):
     vibe's acceptance arrives at turn END, so the user echo lands after
     the assistant chunks — needs the acceptance/display ordering
     redesigned (retagged with a comment).
   - `resume.spec L301` (MCP tools after backend restart): needs the
     task-spawn dialect (retagged with a comment).
   - ask-answer L1534 ("answer delivery deferred until child becomes
     idle"): FIXED — the mock's chat dialect now decomposes
     multi_tool_call fixtures for vibe (see above); the spec is
     untagged and the whole ask-answer file runs for vibe.
   - vibe resume-after-kill race investigation with upstream, fork/undo
     for vibe (needs a session-dir + meta.json fork, not just jsonl
     rewriting — see operations.d).
   - Untagged this session and now PASSING for vibe: session-lifecycle
     "history survives page reload", "no duplicate messages after
     reload", "session resume continues conversation", "sending message
     to stopped session auto-resumes it" — the killed-session race did
     not reproduce in these flows.
4. Local cleanup (optional): probe homes/scripts/logs under /tmp
   (`/tmp/vibe-probe*`, `/tmp/r*.log`, `/tmp/flake-check*.log`,
   `/tmp/vibe-gate-*.txt|json|log`, `/tmp/vibe-repro/`), and the local
   backend config at `~/.config/cydo/config.yaml` (points at
   /tmp/local-ws — remove or restore your own). `example.yaml` at the
   repo root is the user's, intentionally left uncommitted.
5. NOTE from this session: the user's own CyDo backend was running on
   port 3940 during local debugging (workspace /tmp/local-vibe-workspace,
   `/tmp/local-vibe*`). Early local playwright attempts connected to it
   and created two stray tasks there ("restart-alive" probes, ~tids
   27-28) before I switched to an isolated port-3941 repro. Nothing in
   ~/.local/share/cydo/cydo.db was touched (mtime Sep 19); the stray
   tasks live in whatever data dir that backend uses — delete at will.
