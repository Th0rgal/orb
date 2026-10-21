import { test, expect, type Page } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";
// Fast upward scrolling through a long Markdown/code/math transcript must
// never show a row that has not been drawn yet (a virtual gap, a skipped
// content-visibility subtree, or a code block still waiting for colour), and
// must not shift the content under the reader.
const reportOnly = !!process.env.ORB_SCROLL_REPORT_ONLY;
async function settleAtBottom(page: Page) {
  await page.goto("/tests/scroll-up.html");
  await expect(page.locator(".st-text").first()).toBeVisible();
  for (let i = 0; i < 6; i++) { await page.evaluate(() => { const s = document.getElementById("scroller")!; s.scrollTop = s.scrollHeight; }); await page.waitForTimeout(250); }
  // The run is only meaningful from deep in a long transcript.
  expect(await page.evaluate(() => document.getElementById("scroller")!.scrollTop)).toBeGreaterThan(50_000);
}
async function cpu(page: Page) {
  const client = await page.context().newCDPSession(page);
  await client.send("Performance.enable");
  return async () => Object.fromEntries((await client.send("Performance.getMetrics")).metrics.map(m => [m.name, m.value]));
}
async function measure(page: Page, drive: () => Promise<void>) {
  const metrics = await cpu(page);
  const before = await metrics();
  await page.evaluate(() => { (window as any).stopSampling = (window as any).scrollUp.sampler(); });
  await drive();
  const result = await page.evaluate(() => (window as any).stopSampling());
  const after = await metrics();
  const resources = await page.evaluate(() => (window as any).scrollUp.resources());
  return { ...result, cpuTaskMs: Math.round((after.TaskDuration - before.TaskDuration) * 1000), cpuScriptMs: Math.round((after.ScriptDuration - before.ScriptDuration) * 1000), ...resources };
}
// Total px the row under the viewport centre may move beyond the scroll itself.
const ANCHOR_DRIFT_BUDGET = 200;
// Defaults: 1200 px per wheel event every 16 ms (~70k px/s), and a thumb drag
// across the whole transcript in 180 frames. Overridable for stress runs.
const WHEEL_DELTA = Number(process.env.ORB_SCROLL_WHEEL) || 1200;
const DRAG_STEPS = Number(process.env.ORB_SCROLL_DRAG_STEPS) || 180;
const results: Record<string, unknown> = {};
test.afterAll(() => {
  mkdirSync("test-results", { recursive: true });
  writeFileSync(`test-results/scroll-up-${process.env.ORB_SCROLL_LABEL ?? "run"}.json`, JSON.stringify(results, null, 2));
  console.log("SCROLL_UP", JSON.stringify(results));
});
test("fast wheel scroll up paints every visible row", async ({ page }) => {
  await settleAtBottom(page);
  await page.mouse.move(550, 450);
  const r = await measure(page, async () => {
    for (let i = 0; i < 80; i++) { await page.mouse.wheel(0, -WHEEL_DELTA); await page.waitForTimeout(16); }
    await page.waitForTimeout(300);
  });
  results.wheel = r;
  if (!reportOnly) { expect(r.unpaintedFrames).toBe(0); expect(r.anchorDriftPx).toBeLessThan(ANCHOR_DRIFT_BUDGET); }
});
test("scrollbar-style drag up paints every visible row", async ({ page }) => {
  await settleAtBottom(page);
  const r = await measure(page, async () => {
    // A thumb drag: pointer moves arrive as input before each frame and move
    // scrollTop by a large step (the whole 270k px transcript in about 3 s).
    await page.evaluate(async steps => {
      const s = document.getElementById("scroller")!;
      for (let i = 0; i < steps; i++) { const step = Math.min(s.scrollTop, s.scrollHeight / steps); (window as any).scrollUp.intend(step); s.scrollTop -= step; await new Promise(r => setTimeout(r, 16)); }
      await new Promise(r => setTimeout(r, 300));
    }, DRAG_STEPS);
  });
  results.drag = r;
  if (!reportOnly) { expect(r.unpaintedFrames).toBe(0); expect(r.anchorDriftPx).toBeLessThan(ANCHOR_DRIFT_BUDGET); }
});
test("idle resource footprint at the bottom", async ({ page }) => {
  await settleAtBottom(page);
  await page.evaluate(() => (window as any).gc?.());
  results.idle = await page.evaluate(() => (window as any).scrollUp.resources());
});
