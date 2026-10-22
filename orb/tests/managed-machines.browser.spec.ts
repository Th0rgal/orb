import { test, expect, type Page } from "@playwright/test";
import { homedir } from "node:os";

const shots = `${homedir()}/work/paloma/reports/boat-ui`;
const sizes = [
  { size: "small", cpu: 2, ram_gb: 4, disk_gb: 40, usd_per_hour: 0.06 },
  { size: "medium", cpu: 4, ram_gb: 8, disk_gb: 80, usd_per_hour: 0.12 },
  { size: "large", cpu: 8, ram_gb: 16, disk_gb: 160, usd_per_hour: 0.24 },
  { size: "xl", cpu: 16, ram_gb: 32, disk_gb: 320, usd_per_hour: 0.48 },
];
const iso = (offsetMin: number) => new Date(Date.now() + offsetMin * 60_000).toISOString();
const view = (o: Record<string, unknown>) => ({ provider: "boat", provider_id: "bx_7f3k2", image: "sandboxed-node:2026.10", size: "medium", cpu: 4, ram_gb: 8,
  state: "online", created_at: iso(-50), expires_at: iso(70), cost_usd: 0.1, usd_per_hour: 0.12, ledger_closed: false, ...o });

type Opts = { managed?: "404" | "disabled"; createError?: unknown; holdCreate?: boolean; holdDelete?: boolean; settings?: boolean | "404"; theme?: "dark" | "light" };
async function mock(page: Page, opts: Opts = {}) {
  const machines: Record<string, unknown>[] = [
    view({ id: "mm1", name: "medium-a", node_id: "managed-mm1", owner_mission_id: "4f2a9c1e-0000-4000-8000-000000000001", reason: "Lean build" }),
    view({ id: "mm0", name: "medium-b", node_id: "managed-mm0", state: "destroyed", destroyed_at: iso(-120), cost_usd: 0.37, ledger_closed: true }),
  ];
  const budget = { spent_today_usd: 1.24, daily_cap_usd: 20, active: 1, max_concurrent: 3, default_ttl_minutes: 60, max_ttl_minutes: 240, default_size: "medium", max_size: "large" };
  const state = { calls: [] as string[], settings: opts.settings ?? true, releaseCreate: () => {}, releaseDelete: () => {}, advance: (_id: string, _s: Record<string, unknown>) => {} };
  state.advance = (id, patch) => Object.assign(machines.find(m => m.id === id)!, patch);
  let n = 0;
  await page.addInitScript(t => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", t);
  }, opts.theme ?? "dark");
  await page.route("**/api/**", async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname, method = req.method();
    if (path === "/api/managed-machines/settings") {
      state.calls.push(`${method} ${path}${req.postData() ? ` ${req.postData()}` : ""}`);
      if (state.settings === "404") return route.fulfill({ status: 404, body: "" });
      if (method === "PUT") state.settings = JSON.parse(req.postData()!).antigravity_on_managed;
      return route.fulfill({ json: { antigravity_on_managed: state.settings } });
    }
    if (path.startsWith("/api/managed-machines")) {
      state.calls.push(`${method} ${path}${req.postData() ? ` ${req.postData()}` : ""}`);
      if (opts.managed === "404") return route.fulfill({ status: 404, body: "" });
      if (method === "GET") return route.fulfill({ json: { machines, budget, sizes, enabled: opts.managed !== "disabled" } });
      if (method === "POST" && path === "/api/managed-machines") {
        if (opts.holdCreate) await new Promise<void>(r => { state.releaseCreate = r; });
        if (opts.createError) return route.fulfill({ status: 402, json: opts.createError });
        const body = JSON.parse(req.postData() ?? "{}"), id = `mm${++n + 1}`, size = sizes.find(s => s.size === body.size)!;
        const m = view({ id, name: `${body.size}-${"cdef"[n - 1]}`, node_id: `managed-${id}`, size: body.size, cpu: size.cpu, ram_gb: size.ram_gb, usd_per_hour: size.usd_per_hour,
          state: "provisioning", cost_usd: 0, created_at: iso(0), expires_at: iso(body.ttl_minutes) });
        machines.unshift(m); budget.active++;
        return route.fulfill({ status: 201, json: m });
      }
      const id = path.split("/")[3], m = machines.find(x => x.id === id)!;
      if (method === "DELETE") {
        if (opts.holdDelete) await new Promise<void>(r => { state.releaseDelete = r; });
        m.state = "destroyed"; m.destroyed_at = iso(0); budget.active--;
      }
      if (path.endsWith("/extend")) m.expires_at = new Date(Date.parse(m.expires_at as string) + 60 * 60_000).toISOString();
      return route.fulfill({ json: m });
    }
    if (path === "/api/model-routing/chains") return route.fulfill({ json: [{ id: "builtin/smart", name: "Smart (Default)" }] });
    if (path === "/api/providers/antigravity-models") return route.fulfill({ json: [["flash", "Gemini Flash"]] });
    const live = machines.filter(m => m.state !== "destroyed" && m.state !== "failed");
    const json = path === "/api/remote-nodes" ? { enabled: true, remote_launch: { typed: true, harnesses: ["claudecode"], proxy_url_configured: true }, nodes: [
        { id: "spark", status: "online", labels: [], base_url: "", cpu_total: 20 },
        ...live.map(m => ({ id: m.node_id, display_name: m.name, status: "online", labels: ["managed", "boat"], base_url: "", cpu_total: m.cpu, mem_total_bytes: (m.ram_gb as number) * 1024 ** 3 })),
      ] }
      : path === "/api/ai/providers" ? [{ id: "antigravity", name: "Antigravity subscription", provider_type: "antigravity", uses_oauth: true, has_oauth: true, credential_owner: "cli_proxy", status: { type: "connected" } }]
      : path === "/api/projects" ? { projects: [{ slug: "test", title: "Test" }] }
      : path === "/api/backends" ? [{ id: "claudecode", name: "Claude Code" }]
      : path === "/api/providers/backend-models" ? { backends: { claudecode: [{ value: "claude-opus-5", label: "Anthropic — Claude Opus 5" }] } }
      : path === "/api/control/missions" ? [] : {};
    return route.fulfill({ json });
  });
  return state;
}
const openMachines = async (page: Page) => { await page.goto("/"); await page.getByRole("button", { name: "Machines", exact: true }).click(); };
const section = (page: Page) => page.locator(".managed-list").first();
const row = (page: Page, name: string) => section(page).locator(".managed-row", { hasText: name });

for (const theme of ["dark", "light"] as const) test.describe(theme, () => {
  test("rows show names, starting, destroying and errors", async ({ page }) => {
    const api = await mock(page, { theme, holdDelete: true });
    await openMachines(page);
    const online = row(page, "medium-a");
    await expect(online.locator(".managed-name")).toHaveText("medium-a");
    await expect(online).toContainText("medium · 4 vCPU · 8 GB");
    await expect(online).toHaveAttribute("title", /bx_7f3k2/);
    await expect(online.getByRole("button", { name: "Mission 4f2a9c1e" })).toBeVisible();
    // Fleet list: grouped, named, sized.
    await expect(page.locator(".fleet-group-label")).toHaveText("Managed (boat.dev)");
    await expect(page.getByRole("button", { name: /medium-a\s*Managed\s*online · 4 vCPU · 8 GB/ })).toBeVisible();
    await expect(page.getByText("managed-mm1", { exact: true })).toHaveCount(0);
    await page.getByRole("button", { name: "New managed machine" }).click();
    await page.getByRole("dialog", { name: "New managed machine" }).getByRole("button", { name: "Create machine" }).click();
    const starting = row(page, "medium-c");
    await expect(starting).toContainText("Starting…");
    await expect(starting.locator(".managed-spinner")).toBeVisible();
    await page.locator(".managed-head").scrollIntoViewIfNeeded();
    await page.screenshot({ path: `${shots}/managed-starting-online-${theme}.png`, fullPage: true });
    await online.getByRole("button", { name: "Destroy" }).click();
    await page.getByRole("dialog", { name: "Destroy medium-a?" }).getByRole("button", { name: "Destroy" }).click();
    await expect(online).toContainText("Destroying…");
    await expect(online).toHaveClass(/managed-fading/);
    api.advance("mm2", { state: "failed", error: "boat.dev: no capacity in fra1" });
    await expect(row(page, "medium-c")).toContainText("no capacity in fra1");
    await expect(row(page, "medium-c").getByRole("button", { name: "Retry" })).toBeVisible();
    await page.locator(".managed-head").scrollIntoViewIfNeeded();
    await page.screenshot({ path: `${shots}/managed-destroying-error-${theme}.png`, fullPage: true });
    api.releaseDelete();
    await expect(online).toHaveCount(0);
    await expect(page.getByRole("button", { name: /medium-a/ })).toHaveCount(0);
  });

  test("dialog shows the selected size and a live estimate", async ({ page }) => {
    await mock(page, { theme });
    await openMachines(page);
    await page.getByRole("button", { name: "New managed machine" }).click();
    const dialog = page.getByRole("dialog", { name: "New managed machine" });
    await expect(dialog.getByRole("radio")).toHaveCount(3);
    await expect(dialog.getByRole("radio", { name: /medium/ })).toHaveAttribute("aria-checked", "true");
    await expect(dialog.locator(".managed-estimate")).toContainText("medium for 1 h$0.12");
    await dialog.getByRole("radio", { name: /large/ }).click();
    await expect(dialog.locator(".managed-size.on")).toHaveCount(1);
    await expect(dialog.locator(".managed-size.on")).toContainText("large");
    await expect(dialog.locator(".managed-estimate")).toContainText("large for 1 h$0.24");
    await dialog.locator("select").selectOption("240", { force: true });
    await expect(dialog.locator(".managed-estimate")).toContainText("large for 4 h$0.96");
    await page.screenshot({ path: `${shots}/new-machine-dialog-${theme}.png` });
  });

  test("New Agent picker groups managed machines by name", async ({ page }) => {
    await mock(page, { theme });
    await page.goto("/");
    const trigger = page.locator(".na-env-machine, button").filter({ hasText: /Core \(agent-core\)|spark/ }).first();
    await trigger.click();
    const menu = page.locator(".na-menu");
    await expect(menu.locator(".machine-managed-label")).toHaveText("Managed (boat.dev)");
    const option = menu.locator(".machine-node-option", { hasText: "medium-a" });
    await expect(option).toContainText("4 vCPU · 8 GB");
    await expect(menu.getByText("managed-mm1")).toHaveCount(0);
    await page.screenshot({ path: `${shots}/machine-picker-${theme}.png` });
  });

  test("Antigravity card covers managed machines with a toggle", async ({ page }) => {
    const api = await mock(page, { theme });
    await page.goto("/");
    await page.getByRole("button", { name: "Providers", exact: true }).click();
    const native = page.getByRole("region", { name: "Antigravity execution", exact: true });
    await expect(native.getByRole("status")).toHaveText("Available on Core, spark + managed machines");
    const toggle = native.getByRole("switch", { name: "Antigravity on managed machines" });
    await expect(toggle).toHaveAttribute("aria-checked", "true");
    await page.screenshot({ path: `${shots}/antigravity-card-${theme}.png`, fullPage: true });
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-checked", "false");
    expect(api.calls).toContain('PUT /api/managed-machines/settings {"antigravity_on_managed":false}');
    await expect(native.getByRole("status")).toHaveText("Available on Core, spark");
  });
});

test("create is optimistic, polls with wait:false until online", async ({ page }) => {
  const api = await mock(page, { holdCreate: true });
  await openMachines(page);
  await page.getByRole("button", { name: "New managed machine" }).click();
  const dialog = page.getByRole("dialog", { name: "New managed machine" });
  await dialog.getByRole("button", { name: "Create machine" }).click();
  await expect(dialog).toHaveCount(0);
  const placeholder = section(page).locator(".managed-row[data-state=provisioning]");
  await expect(placeholder).toContainText("New machine");
  await expect(placeholder).toContainText("medium · 4 vCPU");
  await expect(placeholder).toContainText("Starting…");
  api.releaseCreate();
  await expect.poll(() => api.calls).toContain('POST /api/managed-machines {"size":"medium","ttl_minutes":60,"wait":false}');
  await expect(row(page, "medium-c")).toContainText("Starting…");
  api.advance("mm2", { state: "enrolling" });
  api.advance("mm2", { state: "online" });
  await expect(row(page, "medium-c")).toContainText("Online", { timeout: 5000 });
});

test("a refused create stays on its row with Retry and Dismiss", async ({ page }) => {
  await mock(page, { createError: { error: "budget_exceeded", message: "Today’s $20.00 cap would be exceeded." } });
  await openMachines(page);
  await page.getByRole("button", { name: "New managed machine" }).click();
  await page.getByRole("dialog", { name: "New managed machine" }).getByRole("button", { name: "Create machine" }).click();
  const failed = section(page).locator(".managed-row[data-state=failed]");
  await expect(failed).toContainText("Daily budget reached: Today’s $20.00 cap would be exceeded.");
  await failed.getByRole("button", { name: "Retry" }).click();
  await expect(failed).toHaveCount(1);
  await failed.getByRole("button", { name: "Dismiss" }).click();
  await expect(failed).toHaveCount(0);
});

test("extend goes through the contract", async ({ page }) => {
  const api = await mock(page);
  await openMachines(page);
  await row(page, "medium-a").getByRole("button", { name: "+1 h" }).click();
  await expect.poll(() => api.calls).toContain('POST /api/managed-machines/mm1/extend {"ttl_minutes":60}');
  await expect(row(page, "medium-a")).toContainText(/2h 0\dm left|2h 1\dm left/);
});

test("recent count includes machines created from the UI once destroyed", async ({ page }) => {
  await mock(page);
  await openMachines(page);
  const toggle = page.getByRole("button", { name: /Recent · last 24 h/ });
  await expect(toggle).toHaveText(/\(1\)/);
  await page.getByRole("button", { name: "New managed machine" }).click();
  await page.getByRole("dialog", { name: "New managed machine" }).getByRole("button", { name: "Create machine" }).click();
  await row(page, "medium-c").getByRole("button", { name: "Destroy" }).click();
  await page.getByRole("dialog", { name: "Destroy medium-c?" }).getByRole("button", { name: "Destroy" }).click();
  await expect(toggle).toHaveText(/\(2\)/);
});

test("new machine sheet survives outside clicks; Escape closes it", async ({ page }) => {
  await mock(page);
  await openMachines(page);
  await page.getByRole("button", { name: "New managed machine" }).click();
  const dialog = page.getByRole("dialog", { name: "New managed machine" });
  await page.mouse.click(20, 450);
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
});

test("older backends: no names, no settings, no managed endpoint", async ({ page }) => {
  await mock(page, { managed: "404", settings: "404" });
  await openMachines(page);
  await expect(page.getByRole("button", { name: /spark online/ })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Managed (boat.dev)" })).toHaveCount(0);
  await page.getByRole("button", { name: "Providers", exact: true }).click();
  const native = page.getByRole("region", { name: "Antigravity execution", exact: true });
  await expect(native.getByRole("status")).toHaveText("Available on Core, spark");
  await expect(native.getByRole("switch")).toHaveCount(0);
});

test("section hides when the backend disables it", async ({ page }) => {
  const api = await mock(page, { managed: "disabled" });
  await openMachines(page);
  await expect.poll(() => api.calls.length).toBeGreaterThan(0);
  await expect(page.getByRole("heading", { name: "Managed (boat.dev)" })).toHaveCount(0);
});
