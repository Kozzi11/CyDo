import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  lastAssistantText,
} from "./fixtures";

// Smoke coverage for the Mistral Vibe driver: plain text turn, shell tool
// round-trip, and session abort. The vibe project points vibe's generic
// backend at the shared mock API (OpenAI chat-completions dialect).
test(
  "vibe basic message and response",
  { tag: "@vibe-only" },
  async ({ page, agentType }) => {
    await enterSession(page);

    await sendMessage(page, 'reply with "OK"');
    await expect(lastAssistantText(page, "OK")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
  },
);

test(
  "vibe tool call flow",
  { tag: "@vibe-only" },
  async ({ page, agentType }) => {
    await enterSession(page);

    await sendMessage(page, "run command echo hello-from-test");

    const timeout = responseTimeout(agentType);
    // Vibe's shell tool is named `bash` on the ACP wire (_meta.tool_name).
    await expect(page.locator(".tool-name", { hasText: "bash" })).toBeVisible({
      timeout,
    });
    await expect(
      page.locator(".tool-result", { hasText: "hello-from-test" }),
    ).toBeVisible({ timeout });

    // After the tool result the mock answers "Done." to close the turn.
    await expect(lastAssistantText(page, "Done.")).toBeVisible({ timeout });
  },
);

test(
  "vibe stop aborts a running session",
  { tag: "@vibe-only" },
  async ({ page, agentType }) => {
    await enterSession(page);

    // "stall session" keeps the mock's SSE stream open, so the turn stays
    // in-flight until Stop cancels it via session/cancel.
    await sendMessage(page, "stall session");
    await expect(page.locator(".btn-banner-stop")).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await page.locator(".btn-banner-stop").click();
    await expect(page.locator(".btn-banner-archive")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
  },
);
