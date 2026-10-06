import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";

// Driver-specific smoke coverage that the shared basic-flow spec cannot
// exercise: cancelling an in-flight turn through vibe's session/cancel.
// The plain message/tool-call flows are already covered by the untagged
// basic-flow.spec.ts tests, which run on the vibe project too.
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
