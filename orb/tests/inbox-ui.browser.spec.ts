import { expect, test, type Page } from "@playwright/test";

async function openInbox(page: Page, theme = "dark", empty = false) {
  await page.clock.setFixedTime(new Date("2026-10-09T12:00:00Z"));
  await page.addInitScript(({ theme }) => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test-token");
    localStorage.setItem("orb-theme", theme);
    localStorage.setItem(`orb.btw:v1:${JSON.stringify([location.origin, "authenticated", "settings:inbox"])}`,
      JSON.stringify({ aiSummary: false, model: "builtin/smart" }));
  }, { theme });
  const missions = empty ? [] : [
    { id: "design", title: "Review the navigation update", project: "orb", status: "awaiting_user",
      history: [{ role: "user", content: "Make the navigation easier to scan." }, { role: "assistant", content: "The navigation is ready. Should archived agents appear below each project or in one shared section?" }] },
    { id: "failed", title: "Restore the workspace connection", project: "infra", status: "failed",
      terminal_reason: "The workspace disconnected before verification completed. Reconnect the machine and retry to finish the checks.", history: [] },
    { id: "done", title: "Keep conversation drafts when switching between projects and reopening a preview", project: "orb", status: "completed",
      history: [{ role: "user", content: "Preserve unfinished follow-ups when the preview is closed." }, { role: "assistant", content: "Drafts now survive closing and reopening the preview. Keyboard navigation and the message composer share the same focus behavior.\n\nVerified in Chromium and WebKit. No messages were sent." }] },
    { id: "working", title: "Run the remaining browser checks", project: "infra", status: "running", history: [] },
  ].map((m, i) => ({ ...m, backend: "claudecode", created_at: "2026-10-09T09:00:00Z", updated_at: `2026-10-09T11:${50 - i * 5}:00Z` }));
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/projects") return route.fulfill({ json: { projects: [{ slug: "orb", title: "Orb", color: "blue" }, { slug: "infra", title: "Infrastructure", color: "purple" }] } });
    if (path === "/api/control/missions") return route.fulfill({ json: missions });
    const match = path.match(/^\/api\/control\/missions\/([^/]+)(\/events)?$/);
    if (match) {
      const mission = missions.find(m => m.id === match[1]);
      if (match[2]) return route.fulfill({ headers: { "X-Orb-Events-Protocol": "1", "X-Has-More": "false" }, json: [] });
      return route.fulfill({ json: mission ?? {} });
    }
    if (path.endsWith("/queue")) return route.fulfill({ json: [] });
    if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
    return route.fulfill({ json: {} });
  });
  await page.goto("/");
  await page.locator("#orb-sidebar").getByRole("button", { name: /^Inbox/ }).click();
  await expect(page.locator(".inbox-page h2")).toHaveText("Inbox");
  // The Inbox itself owns the same width on web and desktop, independent of the sidebar.
  await page.keyboard.press("Meta+b");
  await expect(page.locator(".inbox-skeleton")).toHaveCount(0);
  if (!empty) await expect(page.locator(".inbox-row")).toHaveCount(3);
}

for (const theme of ["dark", "light"]) {
  test(`Inbox list and preview at desktop and 390px: ${theme}`, async ({ page }) => {
    await openInbox(page, theme);
    const inbox = page.locator(".inbox-page");
    await page.mouse.move(0, 0);
    await expect(inbox).toHaveScreenshot(`list-${theme}.png`);
    const row = page.locator('[data-inbox-id="done"]');
    const before = await row.locator(".inbox-headline").boundingBox();
    await row.hover();
    expect(await row.locator(".inbox-headline").boundingBox()).toEqual(before);
    await row.getByRole("button", { name: /^Peek and reply/ }).click();
    await expect(row.locator("textarea")).toBeFocused();
    await expect(row.locator(".inbox-peek-transcript")).toContainText("Verified in Chromium and WebKit");
    await expect(row).toHaveScreenshot(`preview-${theme}.png`);
    await page.keyboard.press("Escape");
    await page.setViewportSize({ width: 390, height: 844 });
    await page.mouse.move(0, 0);
    for (const actions of await inbox.locator(".inbox-triage-btns").all()) {
      await expect(actions).toHaveCSS("opacity", "1");
      await expect(actions).toHaveCSS("pointer-events", "auto");
    }
    await expect(inbox).toHaveScreenshot(`list-mobile-${theme}.png`);
    expect(await inbox.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
    const rowBox = (await row.boundingBox())!;
    const contentBox = (await row.locator(".inbox-row-main-col").boundingBox())!;
    expect(contentBox.x + contentBox.width).toBeLessThan(rowBox.x + rowBox.width);
    await row.getByRole("button", { name: /^Peek and reply/ }).click();
    await expect(row).toHaveScreenshot(`preview-mobile-${theme}.png`);
    expect(await inbox.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
    for (const button of await row.locator(".inbox-triage-btns button").all()) {
      const box = (await button.boundingBox())!;
      expect(box.x + box.width).toBeLessThan(rowBox.x + rowBox.width);
    }
  });

  test(`Inbox keyboard row focus has square edges: ${theme}`, async ({ page }) => {
    await openInbox(page, theme);
    await page.getByRole("tab", { name: /^Unread/ }).focus();
    await page.keyboard.press("ArrowDown");
    const row = page.locator('[data-inbox-id="failed"]');
    await expect(row.locator(".inbox-row-title-btn")).toBeFocused();
    await expect(row).toHaveScreenshot(`keyboard-row-${theme}.png`);
  });

  test(`Inbox empty state: ${theme}`, async ({ page }) => {
    await openInbox(page, theme, true);
    await expect(page.getByRole("status")).toContainText("All caught up on unread responses");
    await expect(page.locator(".inbox-page")).toHaveScreenshot(`empty-${theme}.png`);
  });
}

test("Inbox keyboard filters, focus and a draft survive closing the preview", async ({ page }) => {
  await openInbox(page);
  const unread = page.getByRole("tab", { name: /^Unread/ });
  await unread.focus();
  await page.keyboard.press("ArrowRight");
  await expect(page.getByRole("tab", { name: /^Needs attention/ })).toBeFocused();
  await expect(page.locator(".inbox-row")).toHaveCount(1);
  await page.keyboard.press("End");
  await expect(page.getByRole("tab", { name: /^All/ })).toBeFocused();
  await expect(page.locator(".inbox-row")).toHaveCount(3);
  await page.getByRole("button", { name: "Infrastructure 1", exact: true }).click();
  await expect(page.locator(".inbox-row")).toHaveCount(1);
  await expect(page.getByRole("button", { name: "Infrastructure 1", exact: true })).toHaveAttribute("aria-pressed", "true");
  await page.getByRole("button", { name: "All projects", exact: true }).click();
  const row = page.locator('[data-inbox-id="done"]');
  await row.getByRole("button", { name: /^Peek and reply/ }).focus();
  await expect(row).toHaveClass(/focused/);
  await page.keyboard.press("Enter");
  const draft = row.locator("textarea");
  await draft.fill("Keep this unfinished follow-up.");
  await page.keyboard.press("Escape");
  await expect(row.locator(".inbox-peek-drawer")).toHaveCount(0);
  await row.getByRole("button", { name: /^Peek and reply/ }).click();
  await expect(draft).toHaveValue("Keep this unfinished follow-up.");
  await expect(draft).toBeFocused();
});


test("Inbox rows have one keyboard entry and restore focus after replying", async ({ page }) => {
  await openInbox(page);
  const title = (id: string) => page.locator(`[data-inbox-id="${id}"] .inbox-row-title-btn`);
  await page.getByRole("tab", { name: /^Unread/ }).focus();
  await page.keyboard.press("ArrowDown");
  await expect(title("failed")).toBeFocused();
  await page.keyboard.press("ArrowDown");
  await expect(title("design")).toBeFocused();
  await page.keyboard.press("Home");
  await expect(title("failed")).toBeFocused();
  await page.keyboard.press("End");
  await expect(title("done")).toBeFocused();
  await expect(page.locator('.inbox-row-title-btn[tabindex="0"]')).toHaveCount(1);
  await expect(page.locator('[data-inbox-id="design"] .inbox-act-btn[tabindex="0"]')).toHaveCount(0);
  await page.keyboard.press("Space");
  const row = page.locator('[data-inbox-id="done"]');
  await expect(row.locator(".inbox-peek-drawer")).toBeVisible();
  await row.locator("summary").focus();
  await page.keyboard.press("Enter");
  await expect(row.locator("details")).toHaveAttribute("open", "");
  await expect(row.locator(".inbox-task-text")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(title("done")).toBeFocused();
  await page.keyboard.press("r");
  const draft = row.locator("textarea");
  await expect(draft).toBeFocused();
  await draft.fill("A reply\nwith two lines");
  await page.keyboard.press("ArrowUp");
  await expect(draft).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(title("done")).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(row.getByRole("button", { name: /^Peek and reply/ })).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(draft).toHaveValue("A reply\nwith two lines");
});

test("T focuses an open Peek follow-up and Enter sends it once", async ({page})=>{
 await openInbox(page);
 const sent:unknown[]=[];
 await page.route('**/api/control/message',async route=>{
  sent.push(route.request().postDataJSON());
  await route.fulfill({json:{id:'reply',queued:false,message_accepted:true}});
 });
 const row=page.locator('[data-inbox-id="design"]'), title=row.locator('.inbox-row-title-btn');
 await title.focus();
 await page.keyboard.press('t');
 await expect(row.locator('.inbox-peek-drawer')).toHaveCount(0);
 await page.keyboard.press('Space');
 await expect(row.locator('.inbox-peek-drawer')).toBeVisible();
 await expect(title).toBeFocused();
 await page.keyboard.press('t');
 const input=row.locator('textarea');
 await expect(input).toBeFocused();
 await page.keyboard.type('Test follow-up');
 await page.keyboard.press('Shift+Enter');
 await page.keyboard.type('second line');
 await input.dispatchEvent('keydown',{key:'Enter',isComposing:true});
 expect(sent).toHaveLength(0);
 await expect(input).toHaveValue('Test follow-up\nsecond line');
 await page.keyboard.press('Enter');
 await expect.poll(()=>sent.length).toBe(1);
 expect(sent[0]).toMatchObject({mission_id:'design',content:'Test follow-up\nsecond line'});
 await expect(input).toHaveValue('');
});
