import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("first message renders as collapsed system-user-message with entry point label", { tag: "@no-codex" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  const messageText = 'Please reply with "system-msg-test"';
  await sendMessage(page, messageText);
  await expect(assistantText(page, "system-msg-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  const userMsg = page
    .locator(".message.user-message.system-user-message")
    .first();
  await expect(userMsg).toBeVisible();

  const headerText = await userMsg.locator(".system-user-header").innerText();
  expect(headerText.trim().length).toBeGreaterThan(0);

  const body = userMsg.locator(".system-user-body, .user-text");
  await expect(body.first()).toContainText(messageText);

  const details = userMsg.locator("details.system-user-full-text");
  await expect(details).toBeAttached();
  await expect(details).not.toHaveAttribute("open");

  await details.locator("summary").click();
  await expect(details).toHaveAttribute("open", "");

  const pre = details.locator("pre");
  await expect(pre).toContainText(messageText);
});

test("system-user-message persists after agent confirms the message", { tag: "@no-codex" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  const messageText = 'Please reply with "system-msg-confirm-test"';
  await sendMessage(page, messageText);

  // Wait for the agent to respond — this means the is_replay confirmation echo
  // has replaced the pending message, which is where the cydoMeta bug triggers.
  await expect(assistantText(page, "system-msg-confirm-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // After the agent has responded, the user message must still render as a
  // system-user-message with a label and the original text.
  const userMsg = page
    .locator(".message.user-message.system-user-message")
    .first();
  await expect(userMsg).toBeVisible();

  const headerText = await userMsg.locator(".system-user-header").innerText();
  expect(headerText.trim().length).toBeGreaterThan(0);

  const body = userMsg.locator(".system-user-body, .user-text");
  await expect(body.first()).toContainText(messageText);
});

test("session-start system message stays collapsed after reload", { tag: "@no-codex" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);
  const messageText = 'Please reply with "session-start-replay"';
  await sendMessage(page, messageText);
  await expect(assistantText(page, "session-start-replay")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await page.reload();
  await expect(
    page.locator(".system-user-message", { hasText: "Session start:" }).first(),
  ).toBeVisible();
});

test("task prompt system message keeps task type label after reload", { tag: ["@no-codex"] }, async ({
  page,
  agentType,
}) => {
  const taskCreatedEvents: Array<{
    tid: number;
    relation_type?: string;
  }> = [];
  const taskUpdatedEvents: Array<{ tid: number; alive: boolean }> = [];

  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            relation_type: data.relation_type,
          });
        } else if (data.type === "task_updated" && data.task) {
          taskUpdatedEvents.push({ tid: data.task.tid, alive: data.task.alive });
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  await enterSession(page);
  await sendMessage(page, 'call task research reply with "task-prompt-replay"');

  let childTid: number | null = null;
  await expect(async () => {
    childTid =
      taskCreatedEvents.find((event) => event.relation_type === "subtask")?.tid ??
      null;
    expect(childTid).not.toBeNull();
  }).toPass();

  // Wait for the child to finish: CyDo returns focus to the parent when a
  // sub-task completes, and fast agents (vibe) finish before the sidebar
  // click below — racing the focus-return would keep the parent's view
  // active no matter what we click.
  await expect(async () => {
    const childDone = taskUpdatedEvents.find(
      (event) => event.tid === childTid && !event.alive,
    );
    expect(childDone).toBeTruthy();
  }).toPass();

  // Wait for the parent's turn to end as well: while it is still processing,
  // the focus router keeps pulling the view back to the parent. A late
  // focus_hint (child → parent, emitted when the parent's session digests the
  // sub-task result) can still arrive after the navigation, so retry the
  // visit until it sticks — each hint is one-shot.
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled();

  const childTaskActive = page.locator(`.sidebar-item[data-tid="${childTid}"].active`);
  const childTaskPrompt = page.locator(
    '[style*="display: contents"] .message-list .system-user-message',
    { hasText: "Task prompt: research" },
  );
  await expect(async () => {
    await page.goto(`/local/cydo-test-workspace/task/${childTid}`);
    await expect(childTaskActive).toBeVisible({ timeout: 10_000 });
    await expect(childTaskPrompt).toBeVisible({ timeout: 10_000 });
  }).toPass({ timeout: 120_000 });

  await page.reload();
  await expect(async () => {
    await page.goto(`/local/cydo-test-workspace/task/${childTid}`);
    await expect(childTaskActive).toBeVisible({ timeout: 10_000 });
    await expect(childTaskPrompt).toBeVisible({ timeout: 10_000 });
  }).toPass({ timeout: 120_000 });
});
