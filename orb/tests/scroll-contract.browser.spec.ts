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

test("pinned: frame-by-frame narrowing and viewport height shrink never unpin", async ({ page }) => {
  await page.setViewportSize({ width: 1200, height: 900 });
  await open(page);
  // Consecutive pointer/window-resize steps dispatch the previous frame's
  // programmatic `scroll` event before `ResizeObserver` sees the next narrower
  // layout; the reader must stay pinned throughout.
  const finalMacroGap = await page.evaluate(async () => {
    const main = document.querySelector(".main") as HTMLElement;
    const s = document.getElementById("scroller")!;
    for (let w = 1000; w >= 420; w -= 35) {
      await new Promise<void>(resolve => {
        requestAnimationFrame(() => {
          setTimeout(() => {
            main.style.width = `${w}px`;
            resolve();
          }, 0);
        });
      });
    }
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    return s.scrollHeight - s.scrollTop - s.clientHeight;
  });
  expect(finalMacroGap).toBeLessThan(2);
  await expect(page.locator(".jump-latest")).toBeHidden();

  await width(page, null);
  await page.setViewportSize({ width: 900, height: 540 });
  await frame(page);
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

test("mission view: resizing the side question divider keeps both conversations sticky at the bottom and anchored when scrolled up", async ({ page }) => {
  const longSideAnswer = Array.from(
    { length: 28 },
    (_, i) => `- Bullet ${i + 1}: detailed progress on the remote solver build, branch state, and next scheduled check so this answer overflows and wraps significantly when resized.`,
  ).join("\n") + "\n\nFINAL SIDE LINE";
  await page.setViewportSize({ width: 1500, height: 900 });
  await openMission(page);
  await page.evaluate((ans) => {
    const orig = window.fetch.bind(window);
    const sideEvents: Array<{ id: number; sequence: number; event_type: string; content: string; timestamp: string }> = [];
    const sideMission = { id: "side-child", status: "completed", title: "Side", history: [], tags: ["btw-parent:11111111-0000-4000-8000-000000000001"], created_at: "", updated_at: "" };
    window.fetch = async (input, init) => {
      const url = new URL(String(input), location.origin);
      if (url.pathname.endsWith("/btw/agent")) {
        sideEvents.push(
          { id: 1, sequence: 1, event_type: "user_message", content: "Check status", timestamp: "" },
          { id: 2, sequence: 2, event_type: "assistant_message", content: ans, timestamp: "" },
        );
        return Response.json(sideMission);
      }
      if (url.pathname === "/api/control/missions/side-child/events") {
        const since = url.searchParams.get("since_seq"), before = url.searchParams.get("before_seq");
        const rows = sideEvents.filter(e => (since === null || e.sequence > Number(since)) && (before === null || e.sequence < Number(before)));
        const seqs = rows.map(e => e.sequence);
        const maxAll = sideEvents.length ? Math.max(...sideEvents.map(e => e.sequence)) : 0;
        const headers: Record<string, string> = {
          "X-Orb-Events-Protocol": "1",
          "X-Has-More": "false",
          "X-Max-Sequence": String(maxAll),
        };
        if (seqs.length) {
          headers["X-Page-Max-Sequence"] = String(Math.max(...seqs));
          headers["X-Next-Cursor"] = String(since === null ? Math.min(...seqs) : Math.max(...seqs));
        }
        return Response.json(rows, { headers });
      }
      if (url.pathname === "/api/control/missions/side-child") return Response.json(sideMission);
      return orig(input, init);
    };
  }, longSideAnswer);

  await page.getByRole("button", { name: "Side question", exact: true }).click();
  await page.getByPlaceholder("Ask a side question…").fill("Check status");
  await page.getByPlaceholder("Ask a side question…").press("Enter");
  const sideThread = page.locator(".btw-sidebar .btw-thread");
  await expect(sideThread).toContainText("FINAL SIDE LINE", { timeout: 15000 });
  await frame(page); await frame(page);

  const sGap = () => sideThread.evaluate(s => s.scrollHeight - s.scrollTop - s.clientHeight);
  expect(await mGap(page)).toBeLessThan(2);
  expect(await sGap()).toBeLessThan(2);

  // Drag divider left (shrinking main conversation while widening side conversation).
  const dragDivider = async (dx: number) => {
    const box = (await page.getByRole("separator", { name: "Resize side question panel" }).boundingBox())!;
    await page.mouse.move(box.x + 4, box.y + 200);
    await page.mouse.down();
    await page.mouse.move(box.x + dx, box.y + 200, { steps: 20 });
    await page.mouse.up();
    await frame(page); await frame(page);
  };
  await dragDivider(-320);
  expect(await mGap(page)).toBeLessThan(2);
  expect(await sGap()).toBeLessThan(2);

  // Drag divider right (shrinking side conversation back down).
  await dragDivider(360);
  expect(await mGap(page)).toBeLessThan(2);
  expect(await sGap()).toBeLessThan(2);

  // Scroll the side conversation up, then resize: its top line stays anchored while main stays at bottom.
  await sideThread.hover();
  await page.mouse.wheel(0, -350);
  await frame(page); await frame(page);
  const sideBefore = await sideThread.evaluate(s => {
    const box = s.getBoundingClientRect();
    const hit = document.elementFromPoint(box.left + box.width / 2, box.top + 16)!;
    const el = hit.closest("li,p,[data-side-turn]") ?? hit;
    el.setAttribute("data-side-anchor", "");
    return el.getBoundingClientRect().top;
  });
  await dragDivider(-260);
  await dragDivider(260);
  const sideAfter = await page.locator("[data-side-anchor]").evaluate(e => e.getBoundingClientRect().top);
  expect(Math.abs(sideAfter - sideBefore)).toBeLessThanOrEqual(1);
  expect(await mGap(page)).toBeLessThan(2);
});
