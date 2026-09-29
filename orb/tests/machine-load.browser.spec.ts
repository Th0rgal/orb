import { test, expect } from "@playwright/test";

const GiB = 1024 ** 3;
const node = (id: string, free: number, extra: Record<string, unknown> = {}) => ({ id, status: "online", cordoned: false, labels: [], mem_total_bytes: 128 * GiB, mem_available_bytes: free, ...extra });
const mission = (id: string, where: Record<string, unknown>) => ({ id, title: id, status: "active", history: [], created_at: "", updated_at: "", backend: "claudecode", ...where });

test("the machine picker lists the least busy machine first and counts running agents", async ({ page }) => {
  let fleetReads = 0, missionReads = 0;
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", "dark");
  });
  await page.route("**/api/**", async route => {
    const url = new URL(route.request().url()), path = url.pathname;
    if (path === "/api/model-routing/chains") return route.fulfill({ json: [{ id: "builtin/smart", name: "Smart (Default)" }] });
    if (path === "/api/remote-nodes") {
      fleetReads++;
      return route.fulfill({ json: { enabled: true, remote_launch: { typed: true, harnesses: ["claudecode"], proxy_url_configured: true }, nodes: [
        node("ashur", 30 * GiB), node("babylon", 60 * GiB), node("nippur", 100 * GiB), node("old-agent", 8 * GiB),
        node("sepolia", 120 * GiB, { status: "offline" }),
      ] } });
    }
    if (path === "/api/control/missions" && !url.searchParams.has("project")) {
      missionReads++;
      return route.fulfill({ json: [
        mission("one", { remote_node_id: "nippur" }), mission("two", { remote_node_id: "nippur" }),
        mission("three", { remote_job: { job_id: "j", node_id: "old-agent", phase: "running" } }),
        mission("four", {}),
      ] });
    }
    const json = path === "/api/projects" ? { projects: [{ slug: "test", title: "Test" }] }
      : path === "/api/backends" ? [{ id: "claudecode", name: "Claude Code" }]
      : path === "/api/providers/backend-models" ? { backends: { claudecode: [{ value: "claude-opus-5", label: "Anthropic — Claude Opus 5" }] } }
      : path === "/api/control/missions" ? []
      : path.endsWith("/files") ? { entries: [] }
      : path.endsWith("/crons") ? { jobs: [] }
      : { job: null, runs: [] };
    await route.fulfill({ json });
  });
  await page.goto("/");
  const trigger = page.getByRole("button", { name: /Core \(agent-core\)/ });
  await expect(trigger).toBeVisible({ timeout: 15000 });
  const before = { fleetReads, missionReads };
  await trigger.click();
  const rows = page.locator(".na-menu .machine-node-option");
  // Idle machines by free memory, then busy ones, then the unusable one.
  await expect(rows.locator(".menu-title")).toHaveText(["babylon", "ashur", "old-agent", "nippur", "sepolia"]);
  await expect(rows.nth(0).locator(".machine-load")).toHaveCount(0);
  await expect(rows.nth(2).locator(".machine-load")).toHaveText("1×");
  await expect(rows.nth(3).locator(".machine-load")).toHaveText("2×");
  await expect(rows.nth(3).locator(".machine-load")).toHaveAttribute("title", "2 agents running · 100 GiB of memory free");
  await expect(page.locator(".na-menu .menu-item", { hasText: "Core" }).locator(".machine-load")).toHaveText("1×");
  // The badge must not push the row taller or overlap the state label.
  const row = (await rows.nth(3).boundingBox())!, badge = (await rows.nth(3).locator(".machine-load").boundingBox())!, state = (await rows.nth(3).locator(".machine-node-state").boundingBox())!;
  expect(badge.x + badge.width).toBeLessThanOrEqual(state.x + 0.5);
  expect(badge.y).toBeGreaterThanOrEqual(row.y);
  expect(badge.y + badge.height).toBeLessThanOrEqual(row.y + row.height + 0.5);
  // Opening the menu reuses what Orb already loaded.
  expect({ fleetReads, missionReads }).toEqual(before);
});
