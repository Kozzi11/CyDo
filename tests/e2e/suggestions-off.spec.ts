import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";
import { writeTestConfig } from "./test-config";

// `suggestions: false` stops the backend from generating next-message
// suggestions at all: the one-shot is never issued, so the suggestion bar
// never populates.
test("suggestions: false stops backend generation", async ({
  page,
  agentType,
}) => {
  writeTestConfig(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent: ${agentType}
log_level: trace
suggestions: false
workspaces:
  local:
    root: /tmp/cydo-test-workspace
# Vibe sessions apply the resolved per-task model via vibe's model config
# option, and the real vibe-acp validates it against its catalog — the mock
# profile only defines the "mock" alias, so keep the aliases in this
# replacement config (see flake.nix).
agents:
  vibe:
    model_aliases:
      small:
        model: mock
      medium:
        model: mock
      large:
        model: mock
`,
  );
  // Give the backend's inotify watcher time to reload the config.
  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(page, 'Please reply with "one"');
  await expect(assistantText(page, "one")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // A second full turn bounds the wait without a wall-clock sleep: had the
  // first turn generated suggestions, they would have rendered long before
  // the second turn completes, since the generation one-shot answers from
  // the same mock as the turns themselves.
  await sendMessage(page, 'Please reply with "two"');
  await expect(assistantText(page, "two")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await expect(page.locator(".btn-suggestion")).toHaveCount(0);
});
