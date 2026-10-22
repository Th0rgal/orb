import { expect, test, type Page } from "@playwright/test";

/**
 * Sidebar hierarchy invariants (docs/specs/sidebar-hierarchy.md), replayed
 * against a scripted Core. A frame recorder (MutationObserver + every
 * animation frame) runs in the page for the whole replay and records:
 *  - any row of a known child drawn at a project's root (data-depth=1);
 *  - any watched mission that disappears after it was first shown.
 */

const at = (minute: number) => new Date(Date.UTC(2026, 9, 20, 0, minute)).toISOString();
type Row = Record<string, unknown> & { id: string };
const mission = (id: string, title: string, minute: number, extra: Partial<Row> = {}): Row => ({
  id, title, status: "awaiting_user", project: "assistant", tags: [], history: [], parent_mission_id: null, created_at: at(minute), updated_at: at(minute), ...extra,
});

type Answer = Row[] | Row | { status: number } | undefined;
/** The scripted Core: `list(project)` and `get(id)` are swapped between steps. */
class Core {
  list: (project: string | null, all: boolean) => Answer = () => [];
  get: (id: string) => Answer = () => undefined;
  delayGet = 0;
  async install(page: Page) {
    await page.addInitScript(() => { localStorage.setItem("orb.apiUrl", location.origin); localStorage.setItem("orb.jwt", "test"); });
    await page.route("**/api/**", async route => {
      const url = new URL(route.request().url()), path = url.pathname;
      let json: Answer;
      if (path === "/api/projects") json = { projects: [{ slug: "assistant", title: "Assistant" }, { slug: "other", title: "Other" }] } as unknown as Row;
      else if (path === "/api/control/missions") {
        const offset = Number(url.searchParams.get("offset") ?? 0);
        json = offset ? [] : this.list(url.searchParams.get("project"), url.searchParams.get("all") === "true");
      } else if (path.startsWith("/api/control/missions/") && path.split("/").length === 5) {
        if (this.delayGet) await new Promise(r => setTimeout(r, this.delayGet));
        json = this.get(decodeURIComponent(path.split("/")[4]));
      }
      else if (path.endsWith("/files")) json = { entries: [] } as unknown as Row;
      else if (path.endsWith("/crons")) json = { jobs: [] } as unknown as Row;
      else if (path.endsWith("/controller")) json = { job: null, runs: [] } as unknown as Row;
      else json = {} as Row;
      if (json === undefined) return route.fulfill({ status: 404, json: { error: "not found" } });
      if (!Array.isArray(json) && typeof (json as { status?: unknown }).status === "number" && !("id" in json)) return route.fulfill({ status: (json as { status: number }).status, json: { error: "unavailable" } });
      return route.fulfill({ json });
    });
  }
}

async function record(page: Page, children: string[], watched: string[] = []) {
  await page.addInitScript(({ children, watched }) => {
    const w = window as unknown as { __violations: string[]; __frames: number };
    w.__violations = []; w.__frames = 0;
    const shown = new Set<string>(), kids = new Set(children);
    const check = () => {
      w.__frames++;
      for (const el of document.querySelectorAll('[data-depth="1"][data-tree-id^="m:"]')) {
        const id = el.getAttribute("data-tree-id")!.slice(2);
        if (kids.has(id)) w.__violations.push(`child ${id} at root`);
      }
      for (const id of watched) {
        const visible = !!document.querySelector(`[data-tree-id="m:${id}"]`);
        if (visible) shown.add(id);
        else if (shown.has(id)) w.__violations.push(`mission ${id} disappeared`);
      }
    };
    const frame = () => { check(); requestAnimationFrame(frame); };
    requestAnimationFrame(frame);
    new MutationObserver(check).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ["data-depth", "data-tree-id"] });
  }, { children, watched });
}
const violations = (page: Page) => page.evaluate(() => [...new Set((window as unknown as { __violations: string[] }).__violations)]);
/** Every poller in the Orb runs at once when the window becomes visible. */
const poll = (page: Page) => page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
const openProject = async (page: Page) => { await page.goto("/"); await page.getByRole("button", { name: "Assistant", exact: true }).click(); };
const settle = (page: Page) => page.waitForTimeout(400);

const P = "11111111-1111-4111-8111-111111111111";
const parent = mission(P, "Orchestrator", 0);
const kids = [1, 2, 3].map(i => mission(`c${i}`, `Worker ${i}`, 100 - i, { parent_mission_id: P }));

test("a parent paged out of the list whose first fetch fails never lets its children reach the root", async ({ page }) => {
  const core = new Core();
  let parentReads = 0;
  core.list = () => kids;                                    // the page holds only children
  core.get = id => id === P ? (++parentReads === 1 ? { status: 503 } : parent) : undefined;
  await core.install(page); await record(page, kids.map(k => k.id));
  await openProject(page);
  await expect(page.getByRole("button", { name: /Orchestrator|Parent mission/ }).first()).toBeVisible();
  await poll(page); await settle(page);
  await expect(page.getByRole("button", { name: /Orchestrator/ }).first()).toBeVisible();
  expect(await violations(page)).toEqual([]);
});

test("children that arrive before their slow parent are held under a placeholder", async ({ page }) => {
  const core = new Core();
  core.list = () => kids; core.get = id => id === P ? parent : undefined; core.delayGet = 1200;
  await core.install(page); await record(page, kids.map(k => k.id));
  await openProject(page);
  await expect(page.getByRole("button", { name: /Orchestrator/ }).first()).toBeVisible({ timeout: 10_000 });
  expect(await violations(page)).toEqual([]);
});

test("resuming a callback child whose derived link is missing from later answers keeps it nested", async ({ page }) => {
  // Core derives callback_parent_mission_id from the Hermes state DB; while
  // Hermes restarts, or on a mutation answer, the field is absent.
  const core = new Core();
  const child = mission("cb", "Review", 50, { callback_parent_mission_id: P });
  let withLink = true;
  core.list = () => [withLink ? child : { ...child, callback_parent_mission_id: undefined, status: "running", updated_at: at(200) }, parent];
  core.get = id => id === P ? parent : id === "cb" ? (withLink ? child : { ...child, callback_parent_mission_id: undefined }) : undefined;
  await core.install(page); await record(page, ["cb"]);
  await openProject(page);
  await expect(page.getByRole("button", { name: /Orchestrator/ }).first()).toBeVisible();
  withLink = false;
  for (let i = 0; i < 3; i++) { await poll(page); await settle(page); }
  expect(await violations(page)).toEqual([]);
});

test("a resumed parent with children keeps them nested through status changes", async ({ page }) => {
  const core = new Core();
  let status = "interrupted";
  core.list = () => [{ ...parent, status, updated_at: at(status === "running" ? 300 : 0) }, ...kids];
  core.get = id => id === P ? { ...parent, status } : undefined;
  await core.install(page); await record(page, kids.map(k => k.id));
  await openProject(page);
  await expect(page.getByRole("button", { name: /Orchestrator/ }).first()).toBeVisible();
  for (const next of ["pending", "running", "awaiting_user"]) { status = next; await poll(page); await settle(page); }
  expect(await violations(page)).toEqual([]);
});

test("a parent moved to another project leaves its children under a placeholder, not at the root", async ({ page }) => {
  const core = new Core();
  let moved = false;
  core.list = project => project === "assistant" ? (moved ? kids : [parent, ...kids]) : project === "other" && moved ? [{ ...parent, project: "other" }] : [];
  core.get = id => id === P ? { ...parent, project: moved ? "other" : "assistant" } : undefined;
  await core.install(page); await record(page, kids.map(k => k.id));
  await openProject(page);
  await expect(page.getByRole("button", { name: /Orchestrator/ }).first()).toBeVisible();
  moved = true;
  for (let i = 0; i < 3; i++) { await poll(page); await settle(page); }
  expect(await violations(page)).toEqual([]);
});

test("a reload during streaming rebuilds the same tree without a root frame", async ({ page }) => {
  const core = new Core();
  let minute = 100;
  core.list = () => [...kids.map(k => ({ ...k, status: "running", updated_at: at(minute++) })), parent];
  core.get = id => id === P ? parent : undefined;
  await core.install(page); await record(page, kids.map(k => k.id));
  await openProject(page);
  await expect(page.getByRole("button", { name: /Orchestrator/ }).first()).toBeVisible();
  await poll(page);
  await page.reload();
  await page.getByRole("button", { name: "Assistant", exact: true }).click().catch(() => {});
  await expect(page.getByRole("button", { name: /Orchestrator/ }).first()).toBeVisible();
  await poll(page); await settle(page);
  expect(await violations(page)).toEqual([]);
});

test("Hermes missions stay visible while Core or Hermes restarts (error, then empty, then full)", async ({ page }) => {
  const hermes = [1, 2, 3].map(i => mission(`h${i}`, `Hermes ${i}`, 10 + i, { backend: "cloud_hermes", origin: "hermes", tags: ["origin:hermes-assistant"] }));
  const core = new Core();
  let phase: "full" | "error" | "empty" = "full";
  core.list = () => phase === "error" ? { status: 502 } : phase === "empty" ? [] : hermes;
  core.get = () => undefined;
  await core.install(page); await record(page, [], hermes.map(h => h.id));
  await openProject(page);
  for (const h of hermes) await expect(page.getByRole("button", { name: h.title as string, exact: true })).toBeVisible();
  for (const next of ["error", "error", "empty", "full", "empty", "full"] as const) { phase = next; await poll(page); await settle(page); }
  for (const h of hermes) await expect(page.getByRole("button", { name: h.title as string, exact: true })).toBeVisible();
  expect(await violations(page)).toEqual([]);
});

test("old open missions pushed off the recent-history page are still listed", async ({ page }) => {
  // 100 newer archived rows fill the history page; the open Hermes mission is older.
  const archived = Array.from({ length: 100 }, (_, i) => mission(`a${i}`, `Archived ${i}`, 500 - i, { status: "acknowledged" }));
  const yesterday = new Date(Date.now() - 86_400_000).toISOString();
  const old = mission("old", "Old interrupted Hermes", 1, { status: "interrupted", backend: "cloud_hermes", updated_at: yesterday });
  const live = mission("live", "Old awaiting Hermes", 0, { status: "awaiting_user", backend: "cloud_hermes", updated_at: "2026-08-01T00:00:00Z" });
  const core = new Core();
  core.list = (_project, all) => all ? archived : [old, live];
  await core.install(page);
  await openProject(page);
  await expect(page.getByRole("button", { name: "Old interrupted Hermes", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Old awaiting Hermes", exact: true })).toBeVisible();
});

test("long-dead open missions beyond the page stay hidden; live and recent ones show (prod verity-core shapes)", async ({ page }) => {
  // Real verity-core rows (prod missions DB, 2026-10-22): stale interrupted/failed
  // children of finished parents from Aug-Sep, plus recent and live ones.
  const fixture = (await import("./fixtures/verity-core-open-missions.json", { with: { type: "json" } })).default as { open: (Row & { _parent_status: string | null })[] };
  const shift = Date.now() - Date.parse("2026-10-22T12:00:00Z");
  const move = (t: unknown) => new Date(Date.parse(String(t)) + shift).toISOString();
  const open = fixture.open.map(({ _parent_status, ...r }) => ({ ...r, project: "assistant", created_at: move(r.created_at), updated_at: move(r.updated_at) }));
  const parentStatus = new Map(fixture.open.map(r => [r.id, r._parent_status]));
  const now = Date.now(), week = 7 * 86_400_000;
  const live = new Set(["active", "running", "pending", "queued", "awaiting_user", "resuming", "starting", "waiting_background"]);
  const age = (r: Row) => now - Date.parse(String(r.updated_at));
  const stale = open.filter(r => !live.has(String(r.status)) && age(r) > week);
  // Side agents (btw) and superseded attempts are never sidebar rows.
  const hidden = (r: Row) => (r.tags as string[]).some(t => t.startsWith("btw-parent:") || t.startsWith("superseded"));
  const shownRoots = open.filter(r => !r.parent_mission_id && !hidden(r) && (live.has(String(r.status)) || age(r) <= week));
  const children = open.filter(r => r.parent_mission_id);
  const core = new Core();
  core.list = (project, all) => project && !all ? open : [];
  // Parents are finished (completed/acknowledged) rows, as in prod.
  core.get = id => { const child = open.find(r => r.parent_mission_id === id); return child ? mission(id, `Parent ${id.slice(0, 8)}`, 0, { status: parentStatus.get(child.id) ?? "completed" }) : undefined; };
  await core.install(page); await record(page, children.map(c => c.id));
  await openProject(page);
  for (const r of shownRoots) await expect(page.getByRole("button", { name: String(r.title), exact: true }).first()).toBeVisible();
  await poll(page); await settle(page);
  for (const r of stale) expect(await page.locator(`[data-tree-id="m:${r.id}"]`).count(), `${r.title} (${r.status}, ${r.updated_at})`).toBe(0);
  expect(stale.length).toBeGreaterThan(30);
  expect(await violations(page)).toEqual([]);
});
