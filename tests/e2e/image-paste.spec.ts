import {
  test,
  expect,
  enterSession,
  responseTimeout,
  assistantText,
} from "./fixtures";

// 1x1 red pixel PNG, base64-encoded
const TINY_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";

async function pasteImage(
  page: import("@playwright/test").Page,
  base64: string,
) {
  await page.evaluate((b64) => {
    const binary = atob(b64);
    const array = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) array[i] = binary.charCodeAt(i);
    const blob = new Blob([array], { type: "image/png" });
    const file = new File([blob], "test.png", { type: "image/png" });
    const dt = new DataTransfer();
    dt.items.add(file);
    const event = new Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", { value: dt });
    document.querySelector(".input-textarea")!.dispatchEvent(event);
  }, base64);
}

// No test.describe wrapper: the flake check matrix enumerates only top-level
// specs, so wrapping these tests in a describe would silently exclude them
// from `nix flake check`.
test("paste image into input, send, and verify round-trip", {
  // Codex and Copilot strip image blocks server-side (supportsImages =
  // false), so the mock never sees an image and the user echo carries
  // text only.
  tag: ["@no-codex", "@no-copilot"],
}, async ({ page, agentType }) => {
  await enterSession(page);

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled();

  // Step 1: Simulate pasting an image
  await input.focus();
  await pasteImage(page, TINY_PNG_BASE64);

  // Step 2: Verify image preview appears
  await expect(page.locator(".image-preview img")).toBeVisible();

  // Step 3: Type text and send
  await input.fill("describe this image");
  await page.locator(".btn-send:visible").first().click();

  // Step 4: Verify image appears in the user message in chat history
  await expect(
    page.locator(".message.user-message .user-image"),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Step 5: Verify user message text is also present
  await expect(page.locator(".message.user-message .user-text")).toContainText(
    "describe this image",
  );

  // Step 6: Verify mock API recognized the image and responded
  await expect(assistantText(page, "image received")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Step 7: Verify image preview was cleared from input area after send
  await expect(page.locator(".image-preview img")).not.toBeVisible();
});

test("remove image from preview before sending", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled();

  // Paste an image
  await input.focus();
  await pasteImage(page, TINY_PNG_BASE64);

  // Verify preview appears
  await expect(page.locator(".image-preview img")).toBeVisible();

  // Click remove button
  await page.locator(".image-preview-remove").click();

  // Verify preview is gone
  await expect(page.locator(".image-preview img")).not.toBeVisible();

  // Send text-only message to confirm normal flow still works
  await input.fill('reply with "text only works"');
  await page.locator(".btn-send:visible").first().click();

  await expect(assistantText(page, "text only works")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});
