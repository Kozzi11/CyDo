import { existsSync, readFileSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";

// Empirical finding (probed the real `claude` CLI against the mock Anthropic
// API with and without `--effort`): the resolved effort reaches the outbound
// POST /v1/messages request body as `output_config.effort` — not `thinking`,
// which stays `{"type":"adaptive","display":"omitted"}` regardless of the
// flag. `output_config.effort` defaults to "high" when `--effort` is absent,
// so this spec configures claude's `large` alias to a non-default value
// ("low") — asserting the default "high" would pass even if `--effort` were
// never appended to argv. CyDo's title- and suggestion-generation one-shots
// (both on the unconfigured `small` model class) also echo the probe text,
// so a substring match alone would pick up whichever of the three requests
// happens to land first. Both drivers prefix the session turn's own request
// with CyDo's "Session start: agentic" system message (see
// `known_messages.d`, `KnownSystemMessageKind.sessionStart`), which the
// one-shots never carry — the record predicate below matches on that prefix
// to positively identify the session turn instead of excluding confounders
// one at a time.
type AnthropicCaptureRecord = {
  path: string;
  model: string;
  userText: string | null;
  isToolResult: boolean;
  effort: string | null;
};

type OpenAICaptureRecord = {
  path: string;
  model: string;
  userText: string | null;
  isToolOutput: boolean;
  reasoningEffort: string | null;
};

function readCaptureRecords<T>(capturePath: string, startLine = 0): T[] {
  if (!existsSync(capturePath)) return [];
  return readFileSync(capturePath, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .slice(startLine)
    .map((line) => JSON.parse(line) as T);
}

function isSessionTurnRecord(userText: string | null): boolean {
  return userText?.startsWith("[SYSTEM: Session start:") ?? false;
}

test(
  "Codex per-model-class effort reaches the outbound Responses API request",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    const capturePath = process.env.MOCK_OPENAI_CAPTURE;
    if (!capturePath) {
      throw new Error("MOCK_OPENAI_CAPTURE is unset");
    }
    const probeText = "model effort e2e probe codex";
    const initialCount = readCaptureRecords<OpenAICaptureRecord>(capturePath).length;

    await enterSession(page);
    await sendMessage(page, probeText);
    await expect(assistantText(page, probeText)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await expect
      .poll(
        () =>
          readCaptureRecords<OpenAICaptureRecord>(capturePath, initialCount).find((record) =>
            isSessionTurnRecord(record.userText),
          )?.reasoningEffort ?? null,
        { timeout: responseTimeout(agentType) },
      )
      .toBe("high");
  },
);

test(
  "Claude per-model-class effort reaches the outbound Messages API request",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const capturePath = process.env.MOCK_ANTHROPIC_CAPTURE;
    if (!capturePath) {
      throw new Error("MOCK_ANTHROPIC_CAPTURE is unset");
    }
    const probeText = "model effort e2e probe claude";
    const initialCount = readCaptureRecords<AnthropicCaptureRecord>(capturePath).length;

    await enterSession(page);
    await sendMessage(page, probeText);
    await expect(assistantText(page, probeText)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await expect
      .poll(
        () =>
          readCaptureRecords<AnthropicCaptureRecord>(capturePath, initialCount).find((record) =>
            isSessionTurnRecord(record.userText),
          )?.effort ?? null,
        { timeout: responseTimeout(agentType) },
      )
      .toBe("low");
  },
);

test(
  "Vibe per-task model reaches the outbound chat-completions request",
  { tag: "@vibe-only" },
  async ({ page, agentType }) => {
    const capturePath = process.env.MOCK_OPENAI_CAPTURE;
    if (!capturePath) {
      throw new Error("MOCK_OPENAI_CAPTURE is unset");
    }
    const probeText = "vibe model e2e probe";
    const initialCount = readCaptureRecords<OpenAICaptureRecord>(capturePath).length;

    await enterSession(page);
    await sendMessage(page, probeText);
    await expect(assistantText(page, probeText)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    // CyDo resolves the task type's model class and applies it per session
    // via the `model` ACP config option; vibe then routes the session
    // through the aliased model (config.toml [[models]] name), which is
    // what reaches the mock API.
    await expect
      .poll(
        () =>
          readCaptureRecords<OpenAICaptureRecord>(capturePath, initialCount).find(
            (record) => record.userText?.includes(probeText) ?? false,
          )?.model ?? null,
        { timeout: responseTimeout(agentType) },
      )
      .toBe("mock-model");
  },
);
