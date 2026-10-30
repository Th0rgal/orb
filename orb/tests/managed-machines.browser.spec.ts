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

type Opts = { unlimited?: boolean; managed?: "404" | "disabled"; createError?: unknown; holdCreate?: boolean; holdDelete?: boolean; settings?: boolean | "404"; theme?: "dark" | "light"; spend?: unknown[]; stopped?: boolean; withProviders?: boolean };
async function mock(page: Page, opts: Opts = {}) {
  const providers = opts.withProviders ? [
    { provider: "boat", display_name: "boat.dev", configured: true, enabled: true, credential_source: "bitwarden", key_hint: "••••1234", supports_snapshots: true, supports_free_stop: true, sizes },
    { provider: "hetzner", display_name: "Hetzner Cloud", configured: false, enabled: true, supports_snapshots: false, supports_free_stop: false, sizes: [{ size: "cpx32", cpu: 4, ram_gb: 8, disk_gb: 160, usd_per_hour: 0.062 }] },
    { provider: "vastai", display_name: "Vast.ai", configured: false, enabled: true, supports_snapshots: false, supports_free_stop: false, sizes: [{ size: "rtx4090", cpu: 16, ram_gb: 64, disk_gb: 120, usd_per_hour: 0.45, gpu: "RTX 4090" }] },
    { provider: "scaleway", display_name: "Scaleway", configured: false, enabled: false, supports_snapshots: false, supports_free_stop: false, sizes: [{ size: "PRO2-S", cpu: 4, ram_gb: 16, disk_gb: 80, usd_per_hour: 0.088 }] },
  ] as Record<string, unknown>[] : undefined;
  const machines: Record<string, unknown>[] = [
    view({ id: "mm1", name: "medium-a", node_id: "managed-mm1", owner_mission_id: "4f2a9c1e-0000-4000-8000-000000000001", reason: "Lean build" }),
    view({ id: "mm0", name: "medium-b", node_id: "managed-mm0", state: "destroyed", destroyed_at: iso(-120), cost_usd: 0.37, ledger_closed: true }),
  ];
  if (opts.stopped) machines.push(view({ id: "mm9", name: "large-a", node_id: "managed-mm9", size: "large", state: "stopped", stopped_at: iso(-20), cost_usd: 0.42,
    owner_mission_id: "4f2a9c1e-0000-4000-8000-000000000001" }));
  const snapshots = opts.stopped ? [
    { name: "orb-snap-lean-warm-ab12", label: "lean-native-warm", project: "lean", source_machine_id: "mm9", source_size: "large", created_at: iso(-180), last_used_at: iso(-30), status: "ready", size_bytes: 4.1e9, monthly_usd: 0 },
    { name: "orb-snap-lean-ci-cd34", label: "ci-cache", project: "lean", source_machine_id: "mm1", source_size: "medium", created_at: iso(-2), status: "saving", monthly_usd: 0 },
  ] : [];
  const budget = { spent_today_usd: 1.24, daily_cap_usd: 20, active: 1, max_concurrent: 3, default_ttl_minutes: 60, max_ttl_minutes: 240, default_size: "medium", max_size: "large" } as Record<string, unknown> & { active: number };
  if (opts.unlimited) Object.assign(budget, { daily_cap_usd: null, max_concurrent: null, spent_today_usd: 0.11 });
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
    if (path === "/api/managed-machines/snapshots") return route.fulfill({ json: { snapshots } });
    if (path === "/api/managed-machines/providers" && method === "GET") {
      if (!providers) return route.fulfill({ status: 404, body: "" });
      return route.fulfill({ json: { providers } });
    }
    if (path.startsWith("/api/managed-machines/providers/") && method === "PUT") {
      state.calls.push(`${method} ${path} ${req.postData() ?? ""}`);
      const id = decodeURIComponent(path.split("/").pop()!);
      const pr = providers?.find(p => p.provider === id);
      if (!pr) return route.fulfill({ status: 404, json: { error: "unknown_provider", message: "not found" } });
      const body = JSON.parse(req.postData() ?? "{}");
      if (typeof body.enabled === "boolean") pr.enabled = body.enabled;
      if (typeof body.api_key === "string") {
        if (body.api_key.trim()) {
          pr.configured = true;
          pr.credential_source = "settings";
          pr.key_hint = `••••${body.api_key.trim().slice(-4)}`;
        } else {
          pr.configured = false;
          delete pr.credential_source;
          delete pr.key_hint;
        }
      }
      if (typeof body.region === "string") pr.region = body.region || undefined;
      if (typeof body.project_id === "string") pr.project_id = body.project_id || undefined;
      return route.fulfill({ json: pr });
    }
    if (path.startsWith("/api/managed-machines")) {
      state.calls.push(`${method} ${path}${req.postData() ? ` ${req.postData()}` : ""}`);
      if (opts.managed === "404") return route.fulfill({ status: 404, body: "" });
      if (method === "GET") return route.fulfill({ json: { machines, budget, sizes, enabled: opts.managed !== "disabled", ...(providers ? { providers } : {}), ...(opts.spend ? { daily_spend: opts.spend } : {}) } });
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
      if (path.endsWith("/resume")) { m.state = "provisioning"; budget.active++; return route.fulfill({ status: 202, json: m }); }
      if (path.endsWith("/extend")) m.expires_at = new Date(Date.parse(m.expires_at as string) + 60 * 60_000).toISOString();
      return route.fulfill({ json: m });
    }
    if (path.startsWith("/api/control/missions/")) return route.fulfill({ json: { id: path.split("/").pop(), title: "LeanSys Wave 1 — formalise the scheduler invariants and port the proofs", status: "active" } });
    if (path === "/api/model-routing/chains") return route.fulfill({ json: [{ id: "builtin/smart", name: "Smart (Default)" }] });
    if (path === "/api/providers/antigravity-models") return route.fulfill({ json: [["flash", "Gemini Flash"]] });
    const live = machines.filter(m => m.state !== "destroyed" && m.state !== "failed" && m.state !== "stopped");
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
    await expect(online.locator(".managed-size-label")).toHaveText("medium");
    await expect(online.locator(".managed-spec")).toHaveText("4 vCPU · 8 GB RAM · 80 GB");
    await expect(online.locator(".managed-spec")).not.toHaveCSS("font-family", /mono/i);
    await expect(online.locator(".managed-ttl")).toContainText(/(1 h 1\d|1 h 09) min left/);
    await expect(online.locator(".managed-cost")).toHaveText("$0.10 so far · $0.12/h");
    await expect(online).not.toContainText("Lean build"); // reason only in the tooltip
    await expect(online).toHaveAttribute("title", /Reason: Lean build/);
    await expect(online).toHaveAttribute("title", /bx_7f3k2/);
    await expect(online.locator(".managed-mission-chip")).toContainText("LeanSys Wave 1");
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
    await page.getByRole("button", { name: "Inference", exact: true }).click();
    await page.getByRole("button", { name: /Google Antigravity/ }).click();
    const native = page.getByRole("region", { name: "Antigravity execution", exact: true });
    await expect(native.getByRole("status")).toHaveAttribute("title", new RegExp("^" + "Available on Core, spark + managed machines".replace(/[+]/g, "\\+") + "\\."));
    const toggle = native.getByRole("switch", { name: "Antigravity on managed machines" });
    await expect(toggle).toHaveAttribute("aria-checked", "true");
    await page.screenshot({ path: `${shots}/antigravity-card-${theme}.png`, fullPage: true });
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-checked", "false");
    expect(api.calls).toContain('PUT /api/managed-machines/settings {"antigravity_on_managed":false}');
    await expect(native.getByRole("status")).toHaveAttribute("title", new RegExp("^" + "Available on Core, spark".replace(/[+]/g, "\\+") + "\\."));
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
  await expect(placeholder.locator(".managed-size-label")).toHaveText("medium");
  await expect(placeholder.locator(".managed-spec")).toHaveText("4 vCPU · 8 GB RAM · 80 GB");
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
  await row(page, "medium-a").getByRole("button", { name: "Extend +1 h" }).click();
  await expect.poll(() => api.calls).toContain('POST /api/managed-machines/mm1/extend {"ttl_minutes":60}');
  await expect(row(page, "medium-a")).toContainText(/2 h (0|1)\d min left/);
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
  await page.getByRole("button", { name: "Inference", exact: true }).click();
  await page.getByRole("button", { name: /Google Antigravity/ }).click();
  const native = page.getByRole("region", { name: "Antigravity execution", exact: true });
  await expect(native.getByRole("status")).toHaveAttribute("title", new RegExp("^" + "Available on Core, spark".replace(/[+]/g, "\\+") + "\\."));
  await expect(native.getByRole("switch")).toHaveCount(0);
});

test("section hides when the backend disables it", async ({ page }) => {
  const api = await mock(page, { managed: "disabled" });
  await openMachines(page);
  await expect.poll(() => api.calls.length).toBeGreaterThan(0);
  await expect(page.getByRole("heading", { name: "Managed (boat.dev)" })).toHaveCount(0);
});

for (const theme of ["dark", "light"] as const) test(`row layout: aligned, unlimited budget, narrow overflow (${theme})`, async ({ page }) => {
  await mock(page, { theme, unlimited: true });
  await openMachines(page);
  await expect(page.locator(".managed-budget")).toHaveText("$0.11 spent today · 1 running");
  await expect(page.getByRole("button", { name: "New managed machine" })).toBeEnabled();
  const online = row(page, "medium-a");
  const dot = await online.locator(".managed-status-icon").boundingBox(), name = await online.locator(".managed-name").boundingBox();
  expect(Math.abs((dot!.y + dot!.height / 2) - (name!.y + name!.height / 2))).toBeLessThan(2);
  const actions = await online.locator(".managed-actions").boundingBox(), box = await online.boundingBox();
  expect(Math.abs((actions!.y + actions!.height / 2) - (box!.y + box!.height / 2))).toBeLessThan(2);
  await page.getByRole("button", { name: /Recent · last 24 h/ }).click();
  await expect(section(page).locator(".managed-row.managed-muted")).toHaveCount(0);
  await expect(page.locator(".managed-recent .managed-row.managed-muted")).toHaveCount(1);
  await page.locator(".managed-head").scrollIntoViewIfNeeded();
  await page.screenshot({ path: `${shots}/row-${theme}.png`, fullPage: true });
  await page.getByRole("button", { name: "New managed machine" }).click();
  const dialog = page.getByRole("dialog", { name: "New managed machine" });
  await dialog.locator("select").selectOption("240", { force: true });
  await expect(dialog.getByText(/Exceeds today/)).toHaveCount(0);
  await page.keyboard.press("Escape");
  await page.setViewportSize({ width: 560, height: 900 });
  if (await page.locator(".sidebar-backdrop").isVisible()) await page.locator(".sidebar-backdrop").click();
  await expect(online.getByRole("button", { name: "Destroy" })).toBeHidden();
  const before = (await online.boundingBox())!.height;
  expect(before).toBeLessThan(80);
  await online.getByRole("button", { name: "Actions for medium-a" }).click();
  await expect(page.getByRole("menuitem", { name: "Extend +1 h" })).toBeVisible();
  await page.screenshot({ path: `${shots}/row-narrow-${theme}.png`, fullPage: true });
  await page.getByRole("menuitem", { name: "Destroy" }).click();
  await expect(page.getByRole("dialog", { name: "Destroy medium-a?" })).toBeVisible();
});

test("rows stay mounted across polls (fine-grained updates)", async ({ page }) => {
  await mock(page);
  await openMachines(page);
  const online = row(page, "medium-a");
  await expect(online).toBeVisible();
  await online.evaluate(el => { (el as HTMLElement).dataset.marker = "kept"; });
  await row(page, "medium-a").getByRole("button", { name: "Extend +1 h" }).click();
  await expect(row(page, "medium-a").locator(".managed-ttl")).toContainText(/2 h/);
  await expect(row(page, "medium-a")).toHaveAttribute("data-marker", "kept");
});

const dayIso = (back: number) => new Date(Date.now() - back * 86_400_000).toISOString().slice(0, 10);
const spendWeek = (usd: number[], missions: (string | null)[][] = []) => usd.map((v, i) => ({ day: dayIso(usd.length - 1 - i), usd: v,
  missions: (missions[i] ?? (v > 0 ? ["4f2a9c1e-0000-4000-8000-000000000001"] : [])).map((id, j, all) => ({ mission_id: id, usd: v / all.length })), sizes: [] }));

const open390 = async (page: Page, theme: "dark" | "light", spend: unknown[]) => {
  await mock(page, { theme, spend });
  await openMachines(page);
  await page.getByRole("button", { name: "Toggle sidebar", exact: true }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  return { chart: page.getByTestId("spend-chart"), caption: page.getByTestId("spend-caption") };
};
const idle = "$0.25 today of $20.00 daily cap";
let weekHeight = 0;

for (const theme of ["dark", "light"] as const) test.describe(`spend chart (${theme})`, () => {
  test("week: totals, hover shows the day's top missions, tap pins a day", async ({ page }) => {
    const { chart, caption } = await open390(page, theme, spendWeek([0, 1.0, 2.0, 0.01, 0, 0.5, 0.25], [[], ["4f2a9c1e-0000-4000-8000-000000000001", null, "aaaaaaaa-0000-4000-8000-000000000002"]]));
    await expect(chart).toContainText("$3.76 last 7 days");
    await expect(caption).toHaveText(idle);
    await expect(page.locator(".managed-budget")).toHaveCount(0);
    await expect(chart.locator(".spend-col.zero")).toHaveCount(2);
    const box = (await chart.boundingBox())!;
    weekHeight = box.height;
    const bars = chart.locator(".spend-col");
    await bars.nth(1).hover();
    await expect(caption).toContainText(/\$1\.00 · LeanSys Wave 1.* \$0\.33, No mission \$0\.33 \+1 more/);
    expect((await chart.boundingBox())!.height).toBeCloseTo(box.height, 0);
    await chart.screenshot({ path: `${shots}/spend-week-hover-${theme}.png` });
    await page.mouse.move(0, 0);
    await expect(caption).toHaveText(idle);
    await bars.nth(5).click(); await page.mouse.move(0, 0);
    await expect(caption).toContainText("$0.50");
    await bars.nth(5).click(); await page.mouse.move(0, 0);
    await expect(caption).toHaveText(idle);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
    await page.screenshot({ path: `${shots}/spend-section-390-${theme}.png` });
  });
  test("single day", async ({ page }) => {
    const { chart } = await open390(page, theme, spendWeek([0, 0, 0, 0, 0, 0, 0.04]));
    await expect(chart).toContainText("$0.04 last 7 days");
    await expect(chart.locator(".spend-col.zero")).toHaveCount(6);
    await expect(chart.locator(".spend-col.today .spend-bar")).toHaveAttribute("style", /height: 100%/);
  });
  test("empty week: baselines only, same height", async ({ page }) => {
    const { chart, caption } = await open390(page, theme, spendWeek([0, 0, 0, 0, 0, 0, 0]));
    await expect(chart).toContainText("$0.00 last 7 days");
    await expect(caption).toHaveText("$0.00 today of $20.00 daily cap");
    await expect(page.getByTestId("spend-running")).toHaveText("1 of 3 running");
    await expect(chart.locator(".spend-col.zero")).toHaveCount(7);
    if (weekHeight) expect((await chart.boundingBox())!.height).toBeCloseTo(weekHeight, 0);
    await chart.screenshot({ path: `${shots}/spend-empty-${theme}.png` });
  });
});

test("stopped machines resume optimistically and snapshots are listed", async ({ page }) => {
  const state = await mock(page, { stopped: true });
  await openMachines(page);
  const stopped = page.locator(".managed-stopped .managed-row", { hasText: "large-a" });
  await expect(stopped).toContainText("Stopped");
  const snaps = page.getByLabel("Managed snapshots");
  await expect(snaps).toContainText("lean-native-warm");
  await expect(snaps).toContainText("Saving…");
  await expect(snaps).toContainText("4.1 GB");
  if (process.env.ORB_SCREENSHOT_DIR) await page.screenshot({ path: `${process.env.ORB_SCREENSHOT_DIR}/machines-stopped-snapshots.png`, fullPage: true });
  await stopped.getByRole("button", { name: "Resume" }).click();
  await expect(page.locator(".managed-row", { hasText: "large-a" }).first()).toContainText("Starting…");
  expect(state.calls.some(c => c.startsWith("POST /api/managed-machines/mm9/resume"))).toBe(true);
});

test("machine providers can be configured and toggled in Machines and Settings", async ({ page }) => {
  const state = await mock(page, { withProviders: true });
  await openMachines(page);
  const card = page.getByRole("region", { name: "Machine providers" });
  await expect(card.locator(".managed-provider-row")).toHaveCount(4);
  await expect(card.locator(".managed-provider-row[data-provider=boat]")).toContainText("Configured · Bitwarden ••••1234");
  await expect(card.locator(".managed-provider-row[data-provider=hetzner]")).toContainText("Not configured");
  await expect(card.locator(".managed-provider-row[data-provider=scaleway]")).toContainText("Disabled · Not configured");

  // Configure Hetzner Cloud with an API key and default location.
  await card.getByRole("button", { name: "Configure Hetzner Cloud" }).click();
  const cfg = page.getByRole("dialog", { name: "Configure Hetzner Cloud" });
  await cfg.getByLabel("Hetzner Cloud API key").fill("hz-live-token-9876");
  await cfg.getByLabel("Default location").fill("hel1");
  await cfg.getByRole("button", { name: "Save" }).click();
  await expect(cfg).toHaveCount(0);
  await expect(card.locator(".managed-provider-row[data-provider=hetzner]")).toContainText("Configured · Settings ••••9876 · hel1");
  await expect(page.getByRole("heading", { name: "Managed cloud" })).toBeVisible();

  // New managed machine dialog now offers both boat.dev and Hetzner Cloud.
  await page.getByRole("button", { name: "New managed machine" }).click();
  const newDialog = page.getByRole("dialog", { name: "New managed machine" });
  await expect(newDialog.getByRole("radiogroup", { name: "Provider" }).getByRole("radio")).toHaveCount(2);
  await page.keyboard.press("Escape");

  // Disable Hetzner Cloud via switch -> hides from New managed machine provider picker.
  const hzSwitch = card.getByRole("switch", { name: "Enable Hetzner Cloud" });
  await expect(hzSwitch).toHaveAttribute("aria-checked", "true");
  await hzSwitch.click();
  await expect(hzSwitch).toHaveAttribute("aria-checked", "false");
  expect(state.calls).toContain('PUT /api/managed-machines/providers/hetzner {"enabled":false}');
  await expect(card.locator(".managed-provider-row[data-provider=hetzner]")).toContainText("Disabled · Settings ••••9876 · hel1");

  // Also visible in Settings → Agents → Local agents.
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.getByRole("button", { name: /Agents/ }).click();
  await page.getByRole("tab", { name: "Local agents" }).click();
  const settingsCard = page.getByRole("region", { name: "Machine providers" });
  await expect(settingsCard.locator(".managed-provider-row")).toHaveCount(4);
  await expect(settingsCard.getByRole("switch", { name: "Enable Hetzner Cloud" })).toHaveAttribute("aria-checked", "false");
});
