import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
const out = process.env.ORB_SCREENSHOT_DIR;
for (const theme of ["dark", "light"] as const) {
  test(`start_mission and managed machine calls render as cards outside the work fold (${theme})`, async ({ page }) => {
    await page.goto(`/tests/boat-subagent.html?theme=${theme}`);
    const done = page.locator(".st-subagent[data-status=done]");
    await expect(done).toHaveCount(1);
    await expect(done).toContainText("50000x50000 float32 matrix diagonal sum");
    await expect(done).toContainText("opencode · builtin/smart");
    await expect(done).toContainText("mm4b8tgs9y");
    await expect(done.locator(".st-orch-summary")).toContainText("Diagonal Sums");
    await expect(page.locator(".st-subagent[data-status=failed]").first()).toBeVisible();
    await expect(page.locator(".st-machine[data-state=destroyed]").first()).toContainText("Online → Destroyed");
    // Cards are top-level rows, never inside a collapsed "N other tools" fold.
    await expect(page.locator(".st-work .st-orch")).toHaveCount(0);
    const opened = page.evaluate(() => new Promise<string>(r => window.addEventListener("orb:open-page", e => r((e as CustomEvent).detail), { once: true })));
    await done.locator(".st-orch-open").click();
    expect(await opened).toBe("m:26e6bbcd-2e3e-4c61-8839-578dcb978211");
    if (out) {
      mkdirSync(out, { recursive: true });
      await done.scrollIntoViewIfNeeded();
      await page.screenshot({ path: `${out}/parent-transcript-${theme}.png`, fullPage: false });
    }
  });
}
