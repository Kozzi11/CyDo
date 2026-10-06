import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";

test("system_prompt_template is sent to the LLM API", { tag: "@no-codex" }, async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);
  const passedResults = page.locator(
    ".tool-result-container .text-content:visible",
    {
      hasText: "context-check-passed",
    },
  );

  const rolePromptMarker = Buffer.from("CYDO_TEST_SYSTEM_PROMPT_MARKER").toString(
    "base64",
  );
  const childSessionMarker = Buffer.from(
    "Every child starts a fresh session and does not inherit this conversation or any other task's conversation.",
  ).toString("base64");

  let passCount = await passedResults.count();
  await sendMessage(
    page,
    `call task test_system_prompt check context contains ${rolePromptMarker}`,
  );
  await expect.poll(() => passedResults.count(), { timeout }).toBeGreaterThan(
    passCount,
  );

  passCount = await passedResults.count();
  await sendMessage(
    page,
    `call task test_system_prompt check context contains ${childSessionMarker}`,
  );
  await expect.poll(() => passedResults.count(), { timeout }).toBeGreaterThan(
    passCount,
  );
});

test("codex sends task system prompt through user input text", { tag: "@codex-only" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  const rolePromptMarker = Buffer.from("CYDO_TEST_SYSTEM_PROMPT_MARKER").toString(
    "base64",
  );
  const childSessionMarker = Buffer.from(
    "Every child starts a fresh session and does not inherit this conversation or any other task's conversation.",
  ).toString("base64");
  const passedResults = page.locator(
    ".tool-result-container .text-content:visible",
    {
      hasText: "context-check-passed",
    },
  );
  const timeout = responseTimeout(agentType);

  let passCount = await passedResults.count();
  await sendMessage(
    page,
    `call task test_system_prompt check user text contains ${rolePromptMarker}`,
  );
  await expect.poll(() => passedResults.count(), { timeout }).toBeGreaterThan(
    passCount,
  );

  passCount = await passedResults.count();
  await sendMessage(
    page,
    `call task test_system_prompt check user text contains ${childSessionMarker}`,
  );
  await expect.poll(() => passedResults.count(), { timeout }).toBeGreaterThan(
    passCount,
  );
});
