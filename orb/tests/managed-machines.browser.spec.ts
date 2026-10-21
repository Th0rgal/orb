import { test, expect, type Page } from "@playwright/test";
import { homedir } from "node:os";

const sizes = [
  { size: "small", cpu: 2, ram_gb: 4, disk_gb: 40, usd_per_hour: 0.06 },
  { size: "medium", cpu: 4, ram_gb: 8, disk_gb: 80, usd_per_hour: 0.12 },
  { size: "large", cpu: 8, ram_gb: 16, disk_gb: 160, usd_per_hour: 0.24 },
  { size: "xl", cpu: 16, ram_gb: 32, disk_gb: 320, usd_per_hour: 0.48 },
];
const iso = (offsetMin: number) => new Date(Date.now() + offsetMin * 60_000).toISOString();
const view = (o: Record<string, unknown>) => ({ provider: "boat", provider_id: "boat-1", image: "sandboxed-node:2026.10", size: "medium", cpu: 4, ram_gb: 8,
  state: "online", created_at: iso(-50), expires_at: iso(70), cost_usd: 0.1, usd_per_hour: 0.12, ledger_closed: false, ...o });

async function mock(page: Page, opts: { managed?: "404" | "disabled"; createError?: unknown } = {}) {
  const machines = [
    view({ id: "m1", node_id: "managed-m1", owner_mission_id: "4f2a9c1e-0000-4000-8000-000000000001", reason: "Lean build" }),
    view({ id: "m2", node_id: "managed-m2", size: "small", cpu: 2, ram_gb: 4, usd_per_hour: 0.06, cost_usd: 0.01, state: "provisioning", created_at: iso(-1), expires_at: iso(6) }),
    view({ id: "m0", node_id: "managed-m0", state: "destroyed", destroyed_at: iso(-120), cost_usd: 0.37, ledger_closed: true }),
  ];
  const budget = { spent_today_usd: 1.24, daily_cap_usd: 20, active: 2, max_concurrent: 3, default_ttl_minutes: 60, max_ttl_minutes: 240, default_size: "medium", max_size: "large" };
  const calls: string[] = [];
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
  });
  await page.route("**/api/**", route => {
    const req = route.request(), path = new URL(req.url()).pathname, method = req.method();
    if (path.startsWith("/api/managed-machines")) {
      calls.push(`${method} ${path}${req.postData() ? ` ${req.postData()}` : ""}`);
      if (opts.managed === "404") return route.fulfill({ status: 404, body: "" });
      if (method === "GET") return route.fulfill({ json: { machines, budget, sizes, enabled: opts.managed !== "disabled" } });
      if (method === "POST" && path === "/api/managed-machines") {
        if (opts.createError) return route.fulfill({ status: 402, json: opts.createError });
        const body = JSON.parse(req.postData() ?? "{}");
        const m = view({ id: "m3", node_id: "managed-m3", size: body.size, state: "provisioning", cost_usd: 0, expires_at: iso(body.ttl_minutes) });
        machines.unshift(m); budget.active++;
        return route.fulfill({ json: m });
      }
      const id = path.split("/")[3], m = machines.find(x => x.id === id)!;
      if (method === "DELETE") { m.state = "destroyed"; m.destroyed_at = iso(0); budget.active--; }
      if (path.endsWith("/extend")) m.expires_at = new Date(Date.parse(m.expires_at as string) + 60 * 60_000).toISOString();
      return route.fulfill({ json: m });
    }
    if (path === "/api/model-routing/chains") return route.fulfill({ json: [] });
    const json = path === "/api/remote-nodes" ? { enabled: true, nodes: [
        { id: "spark", status: "online", labels: [], base_url: "", cpu_total: 20 },
        { id: "managed-m1", status: "online", labels: ["managed", "boat"], base_url: "", cpu_total: 4 },
      ] }
      : path === "/api/projects" ? { projects: [] }
      : path === "/api/backends" || path === "/api/control/missions" ? []
      : path === "/api/providers/backend-models" ? { backends: {} } : {};
    return route.fulfill({ json });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Machines", exact: true }).click();
  return calls;
}

for (const theme of ["dark", "light"] as const) test(`managed section lists machines, budget and recent history (${theme})`, async ({ page }) => {
  await page.addInitScript(t => localStorage.setItem("orb-theme", t), theme);
  await mock(page);
  await expect(page.getByRole("heading", { name: "Managed (boat.dev)" })).toBeVisible();
  await expect(page.getByText("$1.24 spent today of $20.00 · 2 of 3 running")).toBeVisible();
  const row = page.locator(".managed-row[data-state=online]");
  await expect(row).toContainText("4 vCPU · 8 GB");
  await expect(row).toContainText(/1h 09m left|1h 10m left/);
  await expect(row).toContainText("$0.12/h");
  await expect(row.getByRole("button", { name: "Mission 4f2a9c1e" })).toBeVisible();
  await expect(page.locator(".managed-row[data-state=provisioning] .managed-urgent")).toContainText(/m \d\ds left/);
  await expect(page.locator(".managed-row[data-state=destroyed]")).toHaveCount(0);
  await page.getByRole("button", { name: /Recent · last 24 h \(1\)/ }).click();
  await expect(page.locator(".managed-row[data-state=destroyed]")).toContainText("Final $0.37 · Ledger closed");
  // The fleet list badges the same machine as managed.
  await expect(page.getByRole("button", { name: /managed-m1/ }).locator(".m-tag")).toHaveText("Managed");
  await page.locator(".managed-head").scrollIntoViewIfNeeded();
  await page.screenshot({ path: `${homedir()}/work/paloma/boat/ui-managed-section-${theme}.png`, fullPage: true });
});

test("extend and destroy go through the contract", async ({ page }) => {
  const calls = await mock(page);
  const row = page.locator(".managed-row[data-state=online]");
  await row.getByRole("button", { name: "+1 h" }).click();
  await expect.poll(() => calls).toContain('POST /api/managed-machines/m1/extend {"ttl_minutes":60}');
  await expect(row).toContainText(/2h 0\dm left|2h 1\dm left/);
  await row.getByRole("button", { name: "Destroy" }).click();
  const dialog = page.getByRole("dialog", { name: "Destroy medium machine?" });
  await expect(dialog).toContainText("mission 4f2a9c1e loses it");
  await dialog.getByRole("button", { name: "Destroy" }).click();
  await expect(dialog).toHaveCount(0);
  expect(calls).toContain("DELETE /api/managed-machines/m1");
  await expect(page.locator(".managed-row[data-state=online]")).toHaveCount(0);
});

test("new managed machine sheet estimates cost and creates", async ({ page }) => {
  const calls = await mock(page);
  await page.getByRole("button", { name: "New managed machine" }).click();
  const dialog = page.getByRole("dialog", { name: "New managed machine" });
  await expect(dialog.getByRole("radio")).toHaveCount(3); // xl is above max_size
  await expect(dialog.getByRole("radio", { name: /medium/ })).toHaveAttribute("aria-checked", "true");
  await expect(dialog.locator(".managed-estimate")).toContainText("$0.12");
  await dialog.getByRole("radio", { name: /large/ }).click();
  await expect(dialog.locator(".managed-estimate")).toContainText("$0.24");
  await page.screenshot({ path: `${homedir()}/work/paloma/boat/ui-managed-new-sheet.png` });
  await dialog.getByRole("button", { name: "Create machine" }).click();
  await expect(dialog).toHaveCount(0);
  expect(calls).toContain('POST /api/managed-machines {"size":"large","ttl_minutes":60}');
  await expect(page.locator(".managed-row[data-state=provisioning]")).toHaveCount(2);
});

test("budget refusals are explained in the sheet", async ({ page }) => {
  await mock(page, { createError: { error: "budget_exceeded", message: "Today’s $20.00 cap would be exceeded." } });
  await page.getByRole("button", { name: "New managed machine" }).click();
  const dialog = page.getByRole("dialog", { name: "New managed machine" });
  await dialog.getByRole("button", { name: "Create machine" }).click();
  await expect(dialog).toContainText("Daily budget reached: Today’s $20.00 cap would be exceeded.");
});

for (const managed of ["404", "disabled"] as const) test(`section hides when the backend ${managed === "404" ? "lacks the endpoint" : "disables it"}`, async ({ page }) => {
  const calls = await mock(page, { managed });
  await expect(page.getByRole("button", { name: /spark online/ })).toBeVisible();
  await expect.poll(() => calls.length).toBeGreaterThan(0);
  await expect(page.getByRole("heading", { name: "Managed (boat.dev)" })).toHaveCount(0);
  await expect(page.getByText(/Couldn’t refresh managed/)).toHaveCount(0);
});
