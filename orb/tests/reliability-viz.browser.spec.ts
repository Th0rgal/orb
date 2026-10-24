import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
const out = process.env.ORB_SCREENSHOT_DIR;

for (const theme of ["dark", "light"] as const) for (const width of [1100, 390]) {
  test(`reliability panel ranks problems and folds healthy rows (${theme}, ${width}px)`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await page.goto(`/tests/reliability-viz.html?theme=${theme}`);
    const table = page.getByRole("table", { name: "Reliability by provider" });
    const rows = table.locator(".st-row");
    await expect(rows.first()).toContainText("minimax · MiniMax-M3");
    await expect(rows.nth(1)).toContainText("openai · gpt-6-astra");
    await expect(rows.nth(1)).toContainText("Personal");
    // Quota exhaustion is amber waiting, not a red failure.
    const quota = rows.filter({ hasText: "gemini-4-argon-high" });
    await expect(quota.locator(".st-pill")).toHaveAttribute("data-tone", "warning");
    await expect(quota.locator(".st-pill")).toContainText("Quota cooldown until");
    await expect(table.getByRole("button", { name: /healthy · show/ })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    if (out) { mkdirSync(out, { recursive: true }); await page.screenshot({ path: `${out}/reliability-${theme}-${width}.png`, fullPage: true }); }
    await rows.nth(1).click();
    await expect(table.locator(".st-detail")).toContainText("503");
    await table.getByRole("button", { name: /healthy · show/ }).click();
    await expect(table).toContainText("grok-4.7");
    if (out) await page.screenshot({ path: `${out}/reliability-${theme}-${width}-expanded.png`, fullPage: true });
  });
}

test("loading renders skeletons of the final size, without a layout jump", async ({ page }) => {
  await page.goto(`/tests/reliability-viz.html?loading=1`);
  const tiles = page.locator(".st-tiles");
  const before = await tiles.boundingBox();
  await expect(page.locator(".st-tile .st-sk")).toHaveCount(4);
  await page.evaluate(() => (window as any).setHealth(null));
  await page.goto(`/tests/reliability-viz.html`);
  const after = await page.locator(".st-tiles").boundingBox();
  expect(Math.abs(after!.height - before!.height)).toBeLessThanOrEqual(1);
});
