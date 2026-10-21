import {eventPage} from "./eventPageFixture";
import { test, expect, type Page, type Locator } from "@playwright/test";

/** Nested menus must open beside the row that opened them, never at the window origin. */
async function setup(page: Page) {
  const source = { id: "original", title: "Original work", status: "active", backend: "grok", model_override: "grok-4.6", project: "test", history: [], created_at: "", updated_at: "" };
  await page.addInitScript(() => { localStorage.setItem("orb.apiUrl", location.origin); localStorage.setItem("orb.jwt", "test"); localStorage.setItem("orb-theme", "dark"); });
  await page.route("**/api/**", async route => {
    const req = route.request(), path = new URL(req.url()).pathname;
    if (path === "/api/model-routing/chains") return route.fulfill({json: ["Smart (Default)", "Cheap", "Fast", "Assistant (Hermes)", "Private (self hosted)", "Reviewer", "Reviewer Scout"].map((name, i) => ({id: `builtin/m${i}`, name}))});
    // Opening the transfer menu refreshes the harness catalog; a late answer rebuilds the
    // harness rows while a submenu is open, which used to strand it at the window origin.
    if (path === "/api/providers/antigravity-models") { await new Promise(r => setTimeout(r, 1200)); return route.fulfill({json: [["argon", "Argon"]]}); }
    if (req.method() !== "GET") return route.fulfill({ status: 400 });
    if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
    const json = path === "/api/projects" ? { projects: [{ slug: "test", title: "Test" }] }
      : path === "/api/backends" ? [{ id: "claudecode", name: "Claude Code" }, { id: "codex", name: "Codex" }, { id: "grok", name: "Grok Build" }, { id: "opencode", name: "OpenCode" }]
      : path === "/api/providers/backend-models" ? { backends: { claudecode: [{ value: "opus", label: "Opus" }], codex: [{ value: "gpt", label: "GPT" }], grok: [{ value: "grok-4.6", label: "Grok 4.6" }] } }
      : path === "/api/control/missions" || path.endsWith("/missions") ? [source]
      : path === "/api/control/missions/original" ? source
      : path.endsWith("/events") || path.endsWith("/queue") ? []
      : path.endsWith("/crons") ? { jobs: [] }
      : path.endsWith("/files") ? { entries: [] }
      : path === "/api/remote-nodes" ? { nodes: [] }
      : { job: null, runs: [] };
    return route.fulfill(path.endsWith("/events") ? eventPage(route, Array.isArray(json) ? json : []) : {json});
  });
  await page.goto("/");
  await page.locator(".row.project .row-main", { hasText: "Test" }).click();
  await page.getByRole("button", { name: /Original work/ }).click();
}

async function expectBeside(page: Page, row: Locator, menu: Locator) {
  await expect(menu).toBeVisible();
  const r = (await row.boundingBox())!, m = (await menu.boundingBox())!, vp = page.viewportSize()!;
  const right = Math.abs(m.x - (r.x + r.width)) <= 12, left = Math.abs(m.x + m.width - r.x) <= 12;
  expect(right || left, `submenu ${JSON.stringify(m)} not beside row ${JSON.stringify(r)}`).toBe(true);
  expect(m.y).toBeLessThan(r.y + r.height);
  expect(m.y + m.height).toBeGreaterThan(r.y);
  expect(m.x).toBeGreaterThanOrEqual(0); expect(m.y).toBeGreaterThanOrEqual(0);
  expect(m.x + m.width).toBeLessThanOrEqual(vp.width); expect(m.y + m.height).toBeLessThanOrEqual(vp.height);
  return {r, m};
}

async function openOpenCode(page: Page, viaKeyboard = false) {
  await page.getByRole("button", { name: "Transfer to another agent", exact: true }).click();
  const menu = page.getByRole("menu", { name: "Transfer to another agent", exact: true });
  await expect(menu).toBeVisible();
  const row = menu.getByRole("menuitem", { name: "OpenCode" });
  const models = page.getByRole("menu", { name: "Choose a model" });
  if (viaKeyboard) {
    // Open the submenu before the catalog refresh lands, away from the pointer.
    await page.mouse.move(5, 5);
    await row.press("ArrowRight");
    await expect(models).toBeVisible();
    await expect(menu.getByRole("menuitem", { name: "Antigravity CLI" })).toBeVisible(); // rows re-rendered
    await expect(models.getByRole("menuitem", { name: "Reviewer Scout" })).toBeVisible();
  } else {
    await expect(menu.getByRole("menuitem", { name: "Antigravity CLI" })).toBeVisible();
    // Visit another harness first: the submenu must follow the hovered row.
    await menu.getByRole("menuitem", { name: "Claude Code" }).hover();
    await expect(models.getByRole("menuitem", { name: "Opus" })).toBeVisible();
    await row.hover();
    await expect(models.getByRole("menuitem", { name: "Reviewer Scout" })).toBeVisible();
  }
  await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
  return {menu, row, models};
}

test("transfer submenu opens beside the hovered harness row", async ({ page }) => {
  await setup(page);
  const {row, models} = await openOpenCode(page);
  const {r, m} = await expectBeside(page, row, models);
  expect(Math.abs(m.x - (r.x + r.width))).toBeLessThanOrEqual(12); // room on the right: opens right
});

test("transfer submenu stays beside its row when the harness rows re-render", async ({ page }) => {
  await setup(page);
  const {row, models} = await openOpenCode(page, true);
  // A provider refresh replaces every harness row; the next scroll anywhere (a streaming
  // transcript) re-places open menus, which used to measure the detached row at (0, 0).
  const refreshed = page.waitForResponse(r => new URL(r.url()).pathname === "/api/backends");
  await page.evaluate(() => window.dispatchEvent(new Event("orb:providers-refresh")));
  await refreshed;
  await page.evaluate(() => new Promise(r => setTimeout(r, 200)));
  await page.evaluate(() => window.dispatchEvent(new Event("scroll")));
  await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
  await expectBeside(page, row, models);
});

test("transfer submenu flips left and up inside a small window", async ({ page }) => {
  await page.setViewportSize({ width: 800, height: 480 });
  await setup(page);
  const {row, models} = await openOpenCode(page);
  const {r, m} = await expectBeside(page, row, models);
  expect(Math.abs(m.x + m.width - r.x)).toBeLessThanOrEqual(12); // no room on the right: flips left
  // Seven models do not fit below a row near the bottom edge: the menu grows upward.
  expect(m.y + m.height).toBeGreaterThan(r.y + r.height - 12);
  expect(m.y).toBeLessThan(r.y);
});
