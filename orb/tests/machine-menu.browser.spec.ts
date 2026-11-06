import { test, expect, type Page } from "@playwright/test";

/**
 * The machine picker's two-line entries (name + status/host caption) used to be
 * squeezed into a fixed 28px `.menu-item`, so the caption rendered on top of the
 * name. These tests measure the real boxes rather than eyeballing a screenshot.
 */
const nodes = [
  { id: "dgx-spark-admin", status: "online", cordoned: true, labels: ["administration", "manual-only"] },
  { id: "dgx-spark", status: "online", cordoned: false },
  { id: "paloma-frankfurt-01", status: "degraded", cordoned: true },
  { id: "hermes-worker-eu-west-1b", status: "offline", cordoned: false },
];

async function setup(page: Page) {
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", "dark");
  });
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if(path === "/api/model-routing/chains") return route.fulfill({json:[{id:"builtin/smart",name:"Smart (Default)"}]});
    const json =
      path === "/api/remote-nodes"
        ? { enabled: true, nodes, remote_launch: { typed: true, harnesses: ["claudecode", "codex"], proxy_url_configured: true } }
        : path === "/api/projects"
          ? { projects: [{ slug: "test", title: "Test" }] }
          : path === "/api/backends"
            ? [{ id: "claudecode", name: "Claude Code" }, { id: "codex", name: "Codex" }]
            : path === "/api/providers/backend-models"
              ? { backends: { claudecode: [{ value: "claude-opus-5", label: "Anthropic — Claude Opus 5" }], codex: [{ value: "gpt-6-astra", label: "OpenAI — GPT-6 Astra" }] } }
              : path === "/api/control/missions"
                ? []
                : path.endsWith("/files")
                  ? { entries: [] }
                  : path.endsWith("/crons")
                    ? { jobs: [] }
                    : { job: null, runs: [] };
    await route.fulfill({ json });
  });
  await page.goto("/");
  await expect(page.getByRole("button", { name: /Core \(agent-core\)/ })).toBeVisible({timeout:15000});
}

/** Every two-line entry: caption strictly below the title, both inside the row. */
async function expectNoOverlap(page: Page) {
  await page.locator(".na-menu").evaluate(async el => { await Promise.all(el.getAnimations().map(animation => animation.finished)); });
  const items = page.locator(".na-menu .menu-item:has(.menu-col)");
  const count = await items.count();
  expect(count).toBeGreaterThan(3); // core + the three nodes
  for (let i = 0; i < count; i++) {
    const item = items.nth(i);
    const row = (await item.boundingBox())!;
    const title = (await item.locator(".menu-title").boundingBox())!;
    expect(title.y).toBeGreaterThanOrEqual(row.y);
    expect(title.y + title.height).toBeLessThanOrEqual(row.y + row.height + 0.5);
    const caption = item.locator(".menu-sub");
    if (await caption.count()) {
      const sub = (await caption.boundingBox())!;
      expect(sub.y).toBeGreaterThanOrEqual(title.y + title.height - 0.5);
      expect(sub.y + sub.height).toBeLessThanOrEqual(row.y + row.height + 0.5);
    }
    const state = item.locator(".machine-node-state");
    if (await state.count()) {
      const box = (await state.boundingBox())!;
      expect(title.x + title.width).toBeLessThanOrEqual(box.x + 0.5);
      expect(box.x + box.width).toBeLessThanOrEqual(row.x + row.width + 0.5);
    }
    if (i + 1 < count) {
      const next = (await items.nth(i + 1).boundingBox())!;
      expect(row.y + row.height).toBeLessThanOrEqual(next.y + 0.5);
    }
  }
}

test("machine picker: two-line entries never overlap, and the footer stays reachable", async ({ page }) => {
  await setup(page);
  await page.getByRole("button", { name: /Core \(agent-core\)/ }).click();
  const menu = page.locator(".na-menu");
  await expect(menu).toBeVisible();

  const committed = menu.locator('[aria-pressed="true"]');
  await expect(committed).toHaveCount(1);
  await page.keyboard.press("End");
  await expect(page.getByRole("button", { name: "Manage machines" })).toBeFocused();
  await expect(committed).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
  expect(await committed.evaluate(el => getComputedStyle(el, "::after").content)).toBe('"✓"');

  await expectNoOverlap(page);
  await expect(menu.locator(".machine-node-option .menu-title", {hasText:/^dgx-spark$/})).toHaveCount(0);

  // Single-line entries keep the 32px rhythm. Measured loosely: a
  // bounding box is reported in device pixels, so a row that is exactly 32 CSS
  // pixels can come back as 31.99993896484375 depending on the display scale.
  const manage = page.getByRole("button", { name: "Manage machines" });
  expect((await manage.boundingBox())!.height).toBeCloseTo(32, 2);

  // Footer is outside the scroll area, so it is visible without scrolling.
  await expect(manage).toBeInViewport();
  const scroller = menu.locator(".na-menu-list");
  await expect(scroller).toHaveCSS("overflow-y", "auto");

  // Selection still works and closes the menu. The trigger then shows the
  // node's display label ("dgx-spark" → "DGX Spark").
  await page.getByRole("button", { name: /DGX Spark · Admin/ }).click();
  await expect(menu).toBeHidden();
  const trigger = page.getByRole("button", { name: /DGX Spark/ });
  await expect(trigger).toBeVisible();

  await trigger.click();
  await expect(page.locator(".na-menu .menu-item.on")).toHaveCount(1);
  await expect(page.locator(".na-menu .menu-item.on .menu-title")).toHaveText("DGX Spark · Admin");
  await page.locator(".na-menu").screenshot({ path: "artifacts/orb-machine-menu-wide.png" });
});

test("machine picker at 375px: wraps inside the viewport with no overlap", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 800 });
  await setup(page);
  await page.getByRole("button", { name: /Core \(agent-core\)/ }).click();
  const menu = page.locator(".na-menu");
  await expect(menu).toBeVisible();

  await expectNoOverlap(page);

  const box = (await menu.boundingBox())!;
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(375);

  await expect(page.getByRole("button", { name: "Manage machines" })).toBeInViewport();
  await page.screenshot({ path: "artifacts/orb-machine-menu-narrow.png" });
});

 test("administration is explicit and never restored as the default machine", async ({page}) => {
 await setup(page);
 await page.getByRole("button", {name:/Core \(agent-core\)/}).click();
 await page.getByRole("button", {name:/DGX Spark · Admin/}).click();
 await expect(page.locator(".na-drop-btn").filter({hasText:"DGX Spark · Administration"})).toBeVisible();
 expect(await page.evaluate(()=>localStorage.getItem("orb.machine"))).toBe("core");
 await page.reload();
 await expect(page.getByRole("button", {name:/Core \(agent-core\)/})).toBeVisible();
 });

test("managed VMs: collapses agent-spawned VMs and starts cloud provider sizes on prompt send", async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", "light");
  });

  const agentNodes = Array.from({ length: 12 }, (_, i) => ({
    id: `managed-ag${i}`,
    display_name: `xlarge-${String.fromCharCode(97 + i)}`,
    status: "online",
    cordoned: false,
    cpu_total: 16,
    mem_total_bytes: 31 * 1024 ** 3,
    labels: ["managed", "boat"],
    owner_kind: "mission",
  }));
  const userNode = {
    id: "managed-usr1",
    display_name: "my-dev-box",
    status: "online",
    cordoned: false,
    cpu_total: 8,
    mem_total_bytes: 16 * 1024 ** 3,
    labels: ["managed", "boat"],
    owner_kind: "user",
  };

  let createManagedCalls = 0;
  let createMissionBody: Record<string, unknown> | null = null;

  await page.route("**/api/**", async (route) => {
    const req = route.request();
    const path = new URL(req.url()).pathname;
    if (path === "/api/model-routing/chains") {
      return route.fulfill({ json: [{ id: "builtin/smart", name: "Smart (Default)" }] });
    }
    if (path === "/api/remote-nodes") {
      return route.fulfill({
        json: {
          enabled: true,
          nodes: [...nodes, userNode, ...agentNodes],
          remote_launch: { typed: true, harnesses: ["claudecode", "codex"], proxy_url_configured: true, antigravity_on_managed: true },
        },
      });
    }
    if (path === "/api/managed-machines") {
      if (req.method() === "POST") {
        createManagedCalls += 1;
        return route.fulfill({ status: 500, json: { error: "should_not_rent_before_send" } });
      }
      return route.fulfill({
        json: {
          enabled: true,
          provider: "boat",
          machines: [],
          budget: {
            spent_today_usd: 0.4,
            daily_cap_usd: null,
            active: 13,
            max_concurrent: null,
            default_ttl_minutes: 120,
            max_ttl_minutes: 720,
            default_size: "small",
            max_size: "xlarge",
          },
          sizes: [],
          providers: [
            {
              provider: "boat",
              display_name: "boat.dev",
              configured: true,
              enabled: true,
              supports_snapshots: true,
              supports_free_stop: true,
              sizes: [
                { size: "small", cpu: 2, ram_gb: 4, disk_gb: 40, usd_per_hour: 0.072 },
                { size: "large", cpu: 8, ram_gb: 16, disk_gb: 80, usd_per_hour: 0.288 },
              ],
            },
            {
              provider: "hetzner",
              display_name: "Hetzner Cloud",
              configured: true,
              enabled: true,
              supports_snapshots: false,
              supports_free_stop: false,
              sizes: [
                { size: "cpx31", cpu: 4, ram_gb: 8, disk_gb: 160, usd_per_hour: 0.025 },
              ],
            },
          ],
        },
      });
    }
    if (path === "/api/projects") return route.fulfill({ json: { projects: [{ slug: "test", title: "Test" }] } });
    if (path === "/api/backends") return route.fulfill({ json: [{ id: "claudecode", name: "Claude Code" }, { id: "codex", name: "Codex" }] });
    if (path === "/api/providers/backend-models") {
      return route.fulfill({ json: { backends: { claudecode: [{ value: "claude-opus-5", label: "Anthropic — Claude Opus 5" }] } } });
    }
    if (path === "/api/control/missions") {
      if (req.method() === "POST") {
        createMissionBody = req.postDataJSON() as Record<string, unknown>;
        return route.fulfill({
          json: {
            id: "m-new-cloud",
            title: "Cloud task",
            status: "running",
            backend: "claudecode",
            remote_node_id: "managed-booted",
            created_at: "2026-11-06T10:00:00Z",
            updated_at: "2026-11-06T10:00:00Z",
          },
        });
      }
      return route.fulfill({ json: [] });
    }
    if (path.startsWith("/api/control/missions/m-new-cloud")) {
      return route.fulfill({
        json: {
          id: "m-new-cloud",
          title: "Cloud task",
          status: "running",
          backend: "claudecode",
          remote_node_id: "managed-booted",
          events: [],
          history: [],
        },
      });
    }
    if (path.endsWith("/files")) return route.fulfill({ json: { entries: [] } });
    if (path.endsWith("/crons")) return route.fulfill({ json: { jobs: [] } });
    return route.fulfill({ json: { job: null, runs: [] } });
  });

  await page.goto("/");
  await expect(page.getByRole("button", { name: /Core \(agent-core\)/ })).toBeVisible({ timeout: 15000 });
  await page.getByRole("button", { name: /Core \(agent-core\)/ }).click();

  const menu = page.locator(".na-menu");
  await expect(menu).toBeVisible();

  // User-started VM is visible under Your VMs, while all 12 agent-spawned VMs are collapsed!
  await expect(menu.locator(".menu-item .menu-title", { hasText: "my-dev-box" })).toBeVisible();
  await expect(menu.locator(".menu-item .menu-title", { hasText: "xlarge-a" })).toHaveCount(0);
  const agentToggle = menu.locator(".machine-agent-vms-toggle");
  await expect(agentToggle).toBeVisible();
  await expect(agentToggle).toContainText("12");

  // Expanding shows agent-spawned VMs; collapsing hides them again cleanly.
  await agentToggle.click();
  await expect(menu.locator(".menu-item .menu-title", { hasText: "xlarge-a" })).toBeVisible();
  await agentToggle.click();
  await expect(menu.locator(".menu-item .menu-title", { hasText: "xlarge-a" })).toHaveCount(0);

  await expectNoOverlap(page);

  // Open boat.dev cascading submenu and pick "large".
  const boatTrigger = menu.locator(".machine-provider-trigger", { hasText: "boat.dev" });
  await expect(boatTrigger).toBeVisible();
  await boatTrigger.click();

  const submenu = page.locator(".machine-submenu");
  await expect(submenu).toBeVisible();
  const largeOption = submenu.locator(".machine-size-option", { hasText: "large" });
  await expect(largeOption).toContainText("$0.29/h");
  await largeOption.click();

  await expect(menu).toBeHidden();
  expect(createManagedCalls).toBe(0);

  // Trigger shows "boat.dev · large" and does not persist to localStorage across reloads.
  await expect(page.locator(".na-drop-btn").filter({ hasText: "boat.dev · large" })).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem("orb.machine"))).toBe("core");

  // Sending the prompt launches with remote_node_id: "auto-managed:boat:large".
  const composer = page.getByRole("textbox").first();
  await composer.fill("Run benchmark on cloud VM");
  await composer.press("Enter");

  await expect.poll(() => createMissionBody).not.toBeNull();
  expect(createMissionBody?.remote_node_id).toBe("auto-managed:boat:large");
  expect(createManagedCalls).toBe(0);
});
