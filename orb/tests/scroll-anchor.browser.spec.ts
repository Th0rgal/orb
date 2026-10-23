import { test, expect, type Page } from "@playwright/test";
// Streaming at the bottom must not move what the reader is looking at when
// they scrolled up, and must keep following when they are at the bottom.
const apply = (page: Page, ev: unknown) => page.evaluate(e => (window as any).anchorHarness.apply(e), ev);
const frame = (page: Page) => page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
/** Stream a run: narration that folds once a tool follows, tools, then many answer lines. */
async function stream(page: Page, sample: () => Promise<void>, prefix = "") {
  for (let t = 0; t < 4; t++) {
    // The first segment continues the text already on screen (deltas are cumulative per segment).
    let text = t ? "" : prefix;
    for (let l = 0; l < 6; l++) { text += `Narration ${t} line ${l}: checking the next thing before calling a tool.\n\n`; await apply(page, { type: "text_delta", data: { content: text } }); await frame(page); await sample(); }
    // A tool after the narration folds it into the Worked line (height shrinks).
    await apply(page, { type: "tool_call", data: { tool_call_id: `t${t}`, name: "read", args: { path: `src/f${t}.ts` } } }); await frame(page); await sample();
    await apply(page, { type: "tool_result", data: { tool_call_id: `t${t}`, result: "ok" } }); await frame(page); await sample();
  }
  let answer = "";
  for (let l = 0; l < 40; l++) { answer += `Answer line ${l} with enough words to wrap a little bit in the column.\n\n`; await apply(page, { type: "text_delta", data: { content: answer } }); await frame(page); await sample(); }
}
const bottomGap = (page: Page) => page.evaluate(() => { const s = document.getElementById("scroller")!; return s.scrollHeight - s.scrollTop - s.clientHeight; });

for (const where of ["middle", "live turn"] as const) test(`scrolled up (${where}): streaming leaves the visible content still`, async ({ page }) => {
  await page.goto("/tests/scroll-anchor.html");
  await page.waitForFunction(() => !!(window as any).anchorHarness);
  // Some of the run already visible, so the reader can scroll into the live turn.
  await apply(page, { type: "text_delta", data: { content: Array.from({ length: 30 }, (_, i) => `Early line ${i} of the live turn.`).join("\n\n") } });
  await apply(page, { type: "tool_call", data: { tool_call_id: "t-pre", name: "read", args: { path: "a.ts" } } });
  await apply(page, { type: "tool_result", data: { tool_call_id: "t-pre", result: "ok" } });
  const visible = Array.from({ length: 30 }, (_, i) => `Visible line ${i} after the first tool.`).join("\n\n") + "\n\n";
  await apply(page, { type: "text_delta", data: { content: visible } });
  await frame(page); await frame(page);
  const scroller = page.locator("#scroller");
  await scroller.hover();
  await page.mouse.wheel(0, where === "middle" ? -4000 : -500);
  await frame(page); await frame(page);
  if (where === "live turn") {
    await page.evaluate(() => { const s = document.getElementById("scroller")!; s.scrollTop += [...document.querySelectorAll(".user")].at(-1)!.getBoundingClientRect().top - s.getBoundingClientRect().top - 40; });
    await frame(page);
  }
  expect(await bottomGap(page)).toBeGreaterThan(200);
  const pick = await page.evaluate(live => {
    const s = document.getElementById("scroller")!, box = s.getBoundingClientRect();
    // In the live turn, its own question bubble at the top of the viewport:
    // the run streams and folds right below it.
    const user = [...document.querySelectorAll(".user")].at(-1)!;
    const el = live ? user : document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)!;
    el.setAttribute("data-anchor", "");
    return el.getBoundingClientRect().top;
  }, where === "live turn");
  let worst = 0;
  const sample = async () => {
    const top = await page.evaluate(() => document.querySelector("[data-anchor]")?.getBoundingClientRect().top ?? NaN);
    worst = Math.max(worst, Math.abs(top - pick));
  };
  await stream(page, sample, visible);
  expect(worst).toBeLessThanOrEqual(1);
  await expect(page.locator(".jump-latest")).toBeVisible();
  await page.locator(".jump-latest").click();
  await expect.poll(() => bottomGap(page)).toBeLessThan(2);
  await expect(page.locator(".jump-latest")).toBeHidden();
});

test("at the bottom: streaming follows the newest line", async ({ page }) => {
  await page.goto("/tests/scroll-anchor.html");
  await page.waitForFunction(() => !!(window as any).anchorHarness);
  await frame(page); await frame(page);
  let worst = 0;
  await stream(page, async () => { worst = Math.max(worst, await bottomGap(page)); });
  expect(worst).toBeLessThan(2);
  await expect(page.locator(".jump-latest")).toBeHidden();
});

test("scrolling up in small steps while streaming escapes the bottom", async ({ page }) => {
  await page.goto("/tests/scroll-anchor.html");
  await page.waitForFunction(() => !!(window as any).anchorHarness);
  await frame(page);
  await page.locator("#scroller").hover();
  let answer = "";
  for (let l = 0; l < 60; l++) {
    answer += `Answer line ${l} with enough words to wrap a little bit in the column.\n\n`;
    await apply(page, { type: "text_delta", data: { content: answer } });
    await page.mouse.wheel(0, -12);
    await frame(page);
  }
  expect(await bottomGap(page)).toBeGreaterThan(400);
});
