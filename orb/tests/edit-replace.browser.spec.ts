import { test, expect } from "@playwright/test";
// Editing a sent message replaces it and what came after (a new version of the
// conversation from that point), like Cursor; it is never appended at the end.
test.use({ browserName: "webkit" });
test("an edited message is resent as a replacement from that message, focused as one field", async ({ page }) => {
  await page.goto("/tests/scroll-mission.html");
  await expect(page.locator("main .scroll")).toContainText("Answer 39", { timeout: 30000 });
  const bubble = page.locator(".user").filter({ hasText: "Question 39:" });
  await bubble.scrollIntoViewIfNeeded();
  await bubble.dblclick();
  const editor = page.getByRole("textbox", { name: "Edit prompt text" });
  await expect(editor).toBeFocused();
  // One focus treatment, on the bubble: no halo drawn around the textarea inside it.
  expect(await editor.evaluate(el => getComputedStyle(el).boxShadow)).toBe("none");
  expect(await page.locator(".user.editing").evaluate(el => getComputedStyle(el).boxShadow)).not.toBe("none");
  await editor.fill("Question 39, rewritten");
  await page.locator(".user.editing").getByRole("button", { name: "Send again" }).click();
  await expect.poll(() => page.evaluate(() => (window as any).forks.length)).toBe(1);
  const fork = await page.evaluate(() => (window as any).forks[0]);
  expect(fork).toMatchObject({ backend: "opencode", replace_message_id: "e79", replacement: "Question 39, rewritten" });
  await expect.poll(() => page.evaluate(() => (window as any).opened)).toEqual(["22222222-0000-4000-8000-000000000002"]);
});
