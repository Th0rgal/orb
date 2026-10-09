import { expect, test, type Page } from "@playwright/test";

async function openInbox(page: Page, theme = "dark", empty = false, aiSummary = false) {
  await page.clock.setFixedTime(new Date("2026-10-09T12:00:00Z"));
  await page.addInitScript(({ theme, aiSummary }) => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test-token");
    localStorage.setItem("orb-theme", theme);
    if (!localStorage.getItem(`orb.btw:v1:${JSON.stringify([location.origin, "authenticated", "settings:inbox"])}`)) localStorage.setItem(`orb.btw:v1:${JSON.stringify([location.origin, "authenticated", "settings:inbox"])}`,
      JSON.stringify({ aiSummary, model: "builtin/smart" }));
    if (aiSummary) {
      const updatedMs = Date.parse("2026-10-09T11:40:00Z");
      localStorage.setItem(`orb.btw:v1:${JSON.stringify([location.origin, "authenticated", "orb:inbox-digest:v7"])}`, JSON.stringify({
        [`done:${updatedMs}:builtin/smart`]: {
          schemaVersion: 7, context: "Keep unfinished follow-ups safe when navigating between conversations.", contextDetails: "Preserve each conversation’s draft across closing, reopening and switching projects.", goal: "An unrelated AI-generated title", task: "", verdict: "waiting", aiGenerated: true, model: "builtin/smart", updatedMs,
          outcome: "The agent reports that drafts now survive closing the preview.",
          unresolved: "The Android behavior still needs a separate check.",
          decision: "Should Android verification be included?",
          suggestions: ["Verify draft restoration on Android too.", "Keep this change scoped to desktop."],
          sources: [{ quote: "Drafts now survive closing and reopening the preview." }],
        },
      }));
    }
  }, { theme, aiSummary });
  const missions = empty ? [] : [
    { id: "design", title: "Review the navigation update", project: "orb", status: "awaiting_user",
      history: [{ role: "user", content: "Make the navigation easier to scan." }, { role: "assistant", content: "The navigation is ready. Should archived agents appear below each project or in one shared section?" }] },
    { id: "failed", title: "Restore the workspace connection", project: "infra", status: "failed",
      terminal_reason: "The workspace disconnected before verification completed. Reconnect the machine and retry to finish the checks.", history: [] },
    { id: "done", title: "Keep conversation drafts when switching between projects and reopening a preview", project: "orb", status: "completed",
      history: [{ role: "user", content: "Preserve unfinished follow-ups when the preview is closed." }, { role: "assistant", content: "Drafts now survive closing and reopening the preview. Keyboard navigation and the message composer share the same focus behavior.\n\nVerified in Chromium and WebKit. No messages were sent." }] },
    { id: "working", title: "Run the remaining browser checks", project: "infra", status: "running", history: [] },
    { id: "automatic", title: "Repair AdversaryModel PR3 blockers", project: "orb", status: "interrupted", origin: "hermes", origin_session_id: null, history: [] },
    { id: "child", title: "Certify PR3 five families", project: "orb", status: "failed", parent_mission_id: "done", history: [] },
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


test("Inbox filters autonomous roots and children by default and permits opting in", async ({ page }) => {
  await openInbox(page);
  await expect(page.locator('[data-inbox-id="automatic"]')).toHaveCount(0);
  await expect(page.locator('[data-inbox-id="child"]')).toHaveCount(0);
  await expect(page.locator('.inbox-sb-badge')).toHaveText('3');
  await page.locator('.inbox-model-pill').click();
  const toggle = page.getByRole('switch', { name: 'Include autonomous agents' });
  await expect(toggle).toHaveAttribute('aria-checked', 'false');
  await toggle.click();
  await page.keyboard.press('Meta+i');
  await expect(page.locator('[data-inbox-id="automatic"]')).toBeVisible();
  await expect(page.locator('[data-inbox-id="child"]')).toBeVisible();
  await expect(page.locator('.inbox-sb-badge')).toHaveText('5');
  await page.locator('.inbox-model-pill').click();
  await page.getByRole('switch', { name: 'Include autonomous agents' }).click();
  await page.keyboard.press('Meta+i');
  await expect(page.locator('[data-inbox-id="automatic"]')).toHaveCount(0);
  await expect(page.locator('.inbox-sb-badge')).toHaveText('3');
});

for (const theme of ['dark', 'light']) {
  test(`Rounded Inbox cards and numbered suggestions: ${theme}`, async ({ page }) => {
    await openInbox(page, theme, false, true);
    const row = page.locator('[data-inbox-id="done"]');
    const statuses: string[] = [];
    await page.route('**/api/control/missions/done/status', async route => {
      statuses.push(route.request().postDataJSON().status);
      await route.fulfill({ json: { ok: true } });
    });
    await row.hover();
    await row.getByRole('button', { name: /^Peek and reply/ }).click();
    await expect(row).toHaveCSS('border-radius', '12px');
    const actions = row.getByRole('group', { name: 'Suggested actions' });
    await expect(actions.locator('kbd')).toHaveText(['1', '2', '3', '4']);
    await row.locator('.inbox-row-title-btn').focus();
    await page.keyboard.press('1');
    await expect(row.locator('textarea')).toHaveValue('Verify draft restoration on Android too.');
    // T focuses the composer; number keys then insert text, including action 3.
    await row.locator('.inbox-row-title-btn').focus();
    await page.keyboard.press('t');
    await expect(row.locator('textarea')).toBeFocused();
    await page.keyboard.type('1234');
    await expect(row.locator('textarea')).toHaveValue('Verify draft restoration on Android too.1234');
    expect(statuses).toEqual([]);
    await page.screenshot({ path: `/tmp/orb-inbox-rounded-${theme}.png` });
    await row.locator('.inbox-row-title-btn').focus();
    await page.keyboard.press('3');
    await expect.poll(() => statuses).toEqual(['acknowledged']);
  });
}

test('A numbered delete action opens confirmation, without deleting or stealing typed digits', async ({ page }) => {
  await openInbox(page);
  let deletes = 0;
  await page.route('**/api/control/missions/done', async route => {
    if (route.request().method() !== 'DELETE') return route.fallback();
    deletes++;
    await route.fulfill({ json: { ok: true } });
  });
  const row = page.locator('[data-inbox-id="done"]');
  await row.hover();
  await row.getByRole('button', { name: /^Peek and reply/ }).click();
  await expect(row.locator('.inbox-suggestions kbd')).toHaveText(['1', '2']);
  await row.locator('textarea').fill('Keep this draft');
  await page.keyboard.type('2');
  await expect(row.locator('textarea')).toHaveValue('Keep this draft2');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await row.locator('.inbox-row-title-btn').focus();
  await page.keyboard.press('2');
  await expect(page.getByRole('dialog', { name: 'Delete 1 agent?' })).toBeVisible();
  expect(deletes).toBe(0);
  await page.keyboard.press('Escape');
  await expect(row.locator('textarea')).toHaveValue('Keep this draft2');
});
