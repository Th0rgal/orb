import { test, expect, type Page } from "@playwright/test";
// The scroll contract (lean/Orb/Scroll.lean): at the bottom, follow; otherwise
// the line at the top of the viewport stays where it is, whatever happens to the
// layout (a side panel narrowing the column, new turns, streaming).
const apply = (page: Page, ev: unknown) => page.evaluate(e => (window as any).anchorHarness.apply(e), ev);
const frame = (page: Page) => page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
const gap = (page: Page) => page.evaluate(() => { const s = document.getElementById("scroller")!; return s.scrollHeight - s.scrollTop - s.clientHeight; });
const width = (page: Page, px: number | null) => page.evaluate(w => { (document.querySelector(".main") as HTMLElement).style.width = w === null ? "" : `${w}px`; }, px);
async function markTop(page: Page) {
  return page.evaluate(() => {
    const s = document.getElementById("scroller")!, box = s.getBoundingClientRect();
    const el = document.elementFromPoint(box.left + box.width / 2, box.top + 12)!.closest("p,h2,.user") ?? document.elementFromPoint(box.left + box.width / 2, box.top + 12)!;
    el.setAttribute("data-anchor", "");
    return el.getBoundingClientRect().top;
  });
}
const anchorTop = (page: Page) => page.evaluate(() => document.querySelector("[data-anchor]")!.getBoundingClientRect().top);

async function open(page: Page) {
  await page.goto("/tests/scroll-anchor.html");
  await page.waitForFunction(() => !!(window as any).anchorHarness);
  await frame(page); await frame(page);
}

test("pinned: narrowing and widening the column (side panel) keeps the bottom", async ({ page }) => {
  await open(page);
  for (const w of [600, 420, 900, null, 500]) {
    await width(page, w); await frame(page);
    expect(await gap(page)).toBeLessThan(2);
  }
  await apply(page, { type: "text_delta", data: { content: "streamed after the resize\n\n".repeat(20) } }); await frame(page);
  expect(await gap(page)).toBeLessThan(2);
  await expect(page.locator(".jump-latest")).toBeHidden();
});

test("scrolled up: narrowing the column (side panel) keeps the top line still", async ({ page }) => {
  await open(page);
  await page.locator("#scroller").hover();
  await page.mouse.wheel(0, -3000); await frame(page); await frame(page);
  const before = await markTop(page);
  for (const w of [600, 420, null]) {
    await width(page, w); await frame(page); await frame(page);
    expect(Math.abs((await anchorTop(page)) - before)).toBeLessThanOrEqual(1);
  }
  await expect(page.locator(".jump-latest")).toBeVisible();
});

test("scrolled up: new turns and streaming never move the top line", async ({ page }) => {
  await open(page);
  await page.locator("#scroller").hover();
  await page.mouse.wheel(0, -1500); await frame(page); await frame(page);
  const before = await markTop(page);
  let worst = 0;
  for (let i = 0; i < 6; i++) {
    let text = "";
    for (let l = 0; l < 8; l++) { text += `Line ${l} of reply ${i}, long enough to wrap in the column a bit.\n\n`; await apply(page, { type: "text_delta", data: { content: text } }); await frame(page); worst = Math.max(worst, Math.abs((await anchorTop(page)) - before)); }
    await apply(page, { type: "assistant_message", data: { content: text, id: `r${i}` } });
    await apply(page, { type: "user_message", data: { content: `Follow-up ${i}`, id: `f${i}` } });
    await frame(page); worst = Math.max(worst, Math.abs((await anchorTop(page)) - before));
  }
  expect(worst).toBeLessThanOrEqual(1);
});

// The real mission view in the app grid.
const scroller = "main .scroll";
async function openMission(page: Page) {
  await page.goto("/tests/scroll-mission.html");
  await expect(page.locator(scroller)).toContainText("Answer 39", { timeout: 30000 });
  await frame(page); await frame(page); await frame(page);
}
const mGap = (page: Page) => page.locator(scroller).evaluate(s => s.scrollHeight - s.scrollTop - s.clientHeight);
async function mMarkTop(page: Page) {
  return page.locator(scroller).evaluate(s => {
    const box = s.getBoundingClientRect();
    const hit = document.elementFromPoint(box.left + box.width / 2, box.top + 12)!;
    const el = hit.closest("p,h2,.user") ?? hit; el.setAttribute("data-anchor", "");
    return el.getBoundingClientRect().top;
  });
}

for (const pinned of [true, false]) test(`mission view: opening the side question panel ${pinned ? "keeps the bottom" : "keeps the top line"}`, async ({ page }) => {
  await page.setViewportSize({ width: 1300, height: 900 });
  await openMission(page);
  expect(await mGap(page)).toBeLessThan(2);
  if (!pinned) { await page.locator(scroller).hover(); await page.mouse.wheel(0, -2500); await frame(page); await frame(page); }
  const before = pinned ? 0 : await mMarkTop(page);
  for (let i = 0; i < 3; i++) {
    await page.getByRole("button", { name: "Side question", exact: true }).click();
    await expect(page.locator(".btw-sidebar .btw-panel")).toBeVisible();
    for (let f = 0; f < 4; f++) {
      await frame(page);
      if (pinned) expect(await mGap(page)).toBeLessThan(2);
      else expect(Math.abs((await page.locator("[data-anchor]").evaluate(e => e.getBoundingClientRect().top)) - before)).toBeLessThanOrEqual(1);
    }
    await page.getByRole("button", { name: "Side question", exact: true }).click();
    await frame(page); await frame(page);
    if (pinned) expect(await mGap(page)).toBeLessThan(2);
    else expect(Math.abs((await page.locator("[data-anchor]").evaluate(e => e.getBoundingClientRect().top)) - before)).toBeLessThanOrEqual(1);
  }
});

test("mission view: a live reply and new message never move a reader who scrolled up", async ({ page }) => {
  await openMission(page);
  await page.locator(scroller).hover(); await page.mouse.wheel(0, -1200); await frame(page); await frame(page);
  const before = await mMarkTop(page);
  const top = () => page.locator("[data-anchor]").evaluate(e => e.getBoundingClientRect().top);
  let worst = 0;
  await page.evaluate(() => (window as any).mainStream("user_message", { content: "A new question", id: "live-u" }));
  await page.evaluate(() => { (window as any).mission.status = "active"; (window as any).mainStream("mission_status_changed", { status: "active" }); });
  let text = "";
  for (let l = 0; l < 25; l++) { text += `Streaming line ${l} that wraps a little in the column of the conversation.\n\n`; await page.evaluate(t => (window as any).mainStream("text_delta", { content: t }), text); await frame(page); worst = Math.max(worst, Math.abs((await top()) - before)); }
  await page.evaluate(t => (window as any).mainStream("assistant_message", { content: t, id: "live-a" }), text);
  for (let f = 0; f < 10; f++) { await frame(page); worst = Math.max(worst, Math.abs((await top()) - before)); }
  expect(worst).toBeLessThanOrEqual(1);
});
