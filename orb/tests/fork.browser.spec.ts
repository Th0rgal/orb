import { eventPage } from "./eventPageFixture";
import { test, expect } from "@playwright/test";

for (const target of [
  { backend: "opencode", name: "OpenCode", shortName: "OpenCode", model: "builtin/smart", label: "Smart (Default)" },
  { backend: "antigravity", name: "Antigravity CLI", shortName: "Antigravity", model: "node-argon", label: "Node Argon" },
]) {
  test(`fork dialog uses ${target.name} on the source destination and archives source only after startup is confirmed`, async ({ page }) => {
    const source: any = { id: "original", title: "Original work", status: "active", backend: "grok", model_override: "grok-4.6", project: "test", remote_node_id: "dgx-spark", history: [], created_at: "", updated_at: "" };
    const fork: any = { ...source, id: "forked", title: "Original work", tags: ["fork-of:original"], updated_at: "2099-01-01T00:00:00Z", backend: target.backend, model_override: target.model };
    let created = false;
    let started = false;
    const mutations: { path: string; body: any }[] = [];
    await page.addInitScript(() => { localStorage.setItem("orb.apiUrl", location.origin); localStorage.setItem("orb.jwt", "test"); localStorage.setItem("orb-theme", "dark"); });
    await page.route("**/api/**", async route => {
      const req = route.request(), path = new URL(req.url()).pathname;
      if (path === "/api/providers/antigravity-models") return route.fulfill({ json: [new URL(req.url()).searchParams.get("node_id") === "dgx-spark" ? ["node-argon", "Node Argon"] : ["core-only", "Core Only"]] });
      if (path === "/api/model-routing/chains") return route.fulfill({ json: [{ id: "builtin/smart", name: "Smart (Default)" }] });
      if (req.method() !== "GET") {
        if (path.endsWith("/inbox-digest") || path.endsWith("/opened") || path.includes("/inbox-state/seen/")) {
          return route.fulfill({ json: {} });
        }
        mutations.push({ path, body: req.postDataJSON() });
        if (path === "/api/control/missions/original/fork") { created = true; return route.fulfill({ json: fork }); }
        if (path === "/api/control/missions/original/cancel") { source.status = "interrupted"; return route.fulfill({ json: {} }); }
        if (path === "/api/control/missions/original/status") { source.status = req.postDataJSON().status; return route.fulfill({ json: source }); }
        return route.fulfill({ status: 400 });
      }
      if (path === "/api/control/stream") {
        const missionId = new URL(req.url()).searchParams.get("mission_id");
        const body = missionId === "forked" && started
          ? `event: thinking\ndata: ${JSON.stringify({ content: "Inspecting workspace", done: true })}\n\n`
          : "";
        return route.fulfill({ contentType: "text/event-stream", body });
      }
      const forkedEvents = started
        ? [
            { id: 1, event_id: "u1", sequence: 1, event_type: "user_message", content: "Carried prompt", timestamp: "" },
            { id: 2, event_id: "t1", sequence: 2, event_type: "thinking", content: "Inspecting workspace", metadata: { done: true }, timestamp: "" },
          ]
        : [{ id: 1, event_id: "u1", sequence: 1, event_type: "user_message", content: "Carried prompt", timestamp: "" }];
      const json = path === "/api/projects" ? { projects: [{ slug: "test", title: "Test" }] }
        : path === "/api/backends" ? [{ id: "grok", name: "Grok Build" }, { id: "opencode", name: "OpenCode" }, { id: "antigravity", name: "Antigravity" }]
        : path === "/api/providers/backend-models" ? { backends: { grok: [{ value: "grok-4.6", label: "Grok 4.6" }], opencode: [{ value: "qwen", label: "Qwen" }] } }
        : path === "/api/control/missions" || path.endsWith("/missions") ? created ? [source, fork].filter(m => m.status !== "acknowledged") : [source]
        : path === "/api/control/missions/original" ? source
        : path === "/api/control/missions/forked" ? fork
        : path === "/api/control/missions/forked/events" ? forkedEvents
        : path.endsWith("/events") || path.endsWith("/queue") ? []
        : path.endsWith("/crons") ? { jobs: [] }
        : path.endsWith("/files") ? { entries: [] }
        : path === "/api/remote-nodes" ? { nodes: [{ id: "dgx-spark", status: "online" }] }
        : { job: null, runs: [] };
      return route.fulfill(path.endsWith("/events") ? eventPage(route, Array.isArray(json) ? json : []) : { json });
    });
    await page.goto("/");
    await page.locator(".row.project .row-main", { hasText: "Test" }).click();
    await page.getByRole("button", { name: /Original work/ }).click();
    await page.getByRole("button", { name: "Transfer to another agent", exact: true }).click();
    const menu = page.getByRole("menu", { name: "Transfer to another agent", exact: true });
    await expect(menu).toBeVisible();
    await menu.getByRole("menuitem", { name: target.name }).click();
    const models = page.getByRole("menu", { name: "Choose a model" });
    await expect(models.getByRole("menuitem", { name: target.label })).toBeVisible();
    await models.getByRole("menuitem", { name: target.label }).click();
    if (target.backend === "antigravity") {
      const efforts = page.getByRole("menu", { name: "Choose effort" });
      await expect(efforts.getByRole("menuitem", { name: "High", exact: true })).toBeVisible();
      await efforts.getByRole("menuitem", { name: "High", exact: true }).click();
    }
    await expect(menu).toHaveCount(0);
    await expect(page.locator(".under-harness")).toHaveText(target.name);
    // Before startup is confirmed, the destination announces Starting <Harness> and source is NOT yet archived.
    await expect(page.locator('.scroll [role="status"]').first()).toContainText(`Starting ${target.shortName}`);
    expect(mutations.map(m => m.path)).toEqual(["/api/control/missions/original/cancel", "/api/control/missions/original/fork"]);

    // Confirm destination startup; source archives cleanly once.
    started = true;
    await expect.poll(() => mutations.map(m => m.path)).toEqual([
      "/api/control/missions/original/cancel",
      "/api/control/missions/original/fork",
      "/api/control/missions/original/status",
    ]);
    expect(mutations[1]).toMatchObject({ body: { backend: target.backend, model_override: target.model } });
    if (target.backend === "antigravity") expect(mutations[1].body.model_effort).toBe("high");
    expect(mutations[2].body).toEqual({ status: "acknowledged" });
    await expect(page.locator(".row.agent.active .row-label")).toHaveText("Original work");
    await expect(page.locator(".row.agent", { hasText: "Original work" })).toHaveCount(1);
  });
}

test("converting Codex to OpenCode builtin/smart never flickers the new mission as a sub-mission on any frame", async ({ page }) => {
  const createdTs = "2026-10-29T02:25:11.000Z";
  const cancelledSourceTs = "2026-10-29T02:25:17.000Z"; // 6s newer than fork.created_at!
  const source: any = {
    id: "codex-orig",
    title: "Migrate Lean kernel",
    status: "active",
    backend: "codex",
    model_override: "gpt-6.1-sol",
    project: "test",
    history: [],
    created_at: "2026-10-29T02:00:00.000Z",
    updated_at: "2026-10-29T02:25:10.000Z",
  };
  const fork: any = {
    ...source,
    id: "opencode-fork",
    status: "pending",
    tags: ["fork-of:codex-orig"],
    backend: "opencode",
    model_override: "builtin/smart",
    created_at: createdTs,
    updated_at: createdTs,
  };
  let created = false;
  let started = false;

  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", "dark");
    const w = window as unknown as { __forkViolations: string[] };
    w.__forkViolations = [];
    const check = () => {
      const forkEl = document.querySelector('[data-tree-id="m:opencode-fork"]');
      if (forkEl) {
        const depth = Number(forkEl.getAttribute("data-depth") ?? "0");
        if (depth > 1) w.__forkViolations.push(`fork rendered nested at depth=${depth}`);
        if (forkEl.querySelector(".row-version-tag")) w.__forkViolations.push("fork rendered with earlier version badge");
        const label = forkEl.querySelector(".row-label")?.textContent?.trim() ?? "";
        if (label.includes("OpenCode") || label.includes("builtin/smart")) {
          w.__forkViolations.push(`fork rendered with versionLabel "${label}"`);
        }
      }
    };
    const loop = () => { check(); requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
    new MutationObserver(check).observe(document, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
      attributeFilter: ["data-depth", "data-tree-id", "class"],
    });
  });

  await page.route("**/api/**", async route => {
    const req = route.request(), path = new URL(req.url()).pathname;
    if (path === "/api/model-routing/chains") return route.fulfill({ json: [{ id: "builtin/smart", name: "Smart (Default)" }] });
    if (req.method() !== "GET") {
      if (path.endsWith("/inbox-digest") || path.endsWith("/opened") || path.includes("/inbox-state/seen/")) {
        return route.fulfill({ json: {} });
      }
      if (path === "/api/control/missions/codex-orig/cancel") {
        source.status = "interrupted";
        source.updated_at = cancelledSourceTs;
        return route.fulfill({ json: {} });
      }
      if (path === "/api/control/missions/codex-orig/fork") {
        created = true;
        return route.fulfill({ json: fork });
      }
      if (path === "/api/control/missions/codex-orig/status") {
        await new Promise(r => setTimeout(r, 400));
        source.status = req.postDataJSON().status;
        return route.fulfill({ json: source });
      }
      return route.fulfill({ status: 400 });
    }
    if (path === "/api/control/stream") {
      const missionId = new URL(req.url()).searchParams.get("mission_id");
      const body = missionId === "opencode-fork" && started
        ? `event: thinking\ndata: ${JSON.stringify({ content: "Running OpenCode", done: true })}\n\n`
        : "";
      return route.fulfill({ contentType: "text/event-stream", body });
    }
    const forkedEvents = started
      ? [
          { id: 1, event_id: "u1", sequence: 1, event_type: "user_message", content: "Carried prompt", timestamp: "" },
          { id: 2, event_id: "t1", sequence: 2, event_type: "thinking", content: "Running OpenCode", metadata: { done: true }, timestamp: "" },
        ]
      : [{ id: 1, event_id: "u1", sequence: 1, event_type: "user_message", content: "Carried prompt", timestamp: "" }];
    const json = path === "/api/projects" ? { projects: [{ slug: "test", title: "Test" }] }
      : path === "/api/backends" ? [{ id: "codex", name: "Codex" }, { id: "opencode", name: "OpenCode" }]
      : path === "/api/providers/backend-models" ? { backends: { codex: [{ value: "gpt-6.1-sol", label: "GPT 6.1 Sol" }], opencode: [] } }
      : path === "/api/control/missions" || path.endsWith("/missions") ? created ? [source, fork].filter(m => m.status !== "acknowledged") : [source]
      : path === "/api/control/missions/codex-orig" ? source
      : path === "/api/control/missions/opencode-fork" ? fork
      : path === "/api/control/missions/opencode-fork/events" ? forkedEvents
      : path.endsWith("/events") || path.endsWith("/queue") ? []
      : path.endsWith("/crons") ? { jobs: [] }
      : path.endsWith("/files") ? { entries: [] }
      : path === "/api/remote-nodes" ? { nodes: [] }
      : { job: null, runs: [] };
    return route.fulfill(path.endsWith("/events") ? eventPage(route, Array.isArray(json) ? json : []) : { json });
  });

  await page.goto("/");
  await page.locator(".row.project .row-main", { hasText: "Test" }).click();
  await page.getByRole("button", { name: /Migrate Lean kernel/ }).click();
  await page.getByRole("button", { name: "Transfer to another agent", exact: true }).click();
  const menu = page.getByRole("menu", { name: "Transfer to another agent", exact: true });
  await menu.getByRole("menuitem", { name: "OpenCode" }).click();
  const models = page.getByRole("menu", { name: "Choose a model" });
  await models.getByRole("menuitem", { name: "Smart (Default)" }).click();

  // Hold destination in `destination_starting` for 800ms while pollers fire and source has a newer updated_at!
  await expect(page.locator('[data-tree-id="m:opencode-fork"]')).toBeVisible();
  await expect(page.locator('[data-tree-id="m:opencode-fork"]')).toHaveAttribute("data-depth", "1");
  await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
  await page.waitForTimeout(800);

  started = true;
  await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
  await expect(page.locator('[data-tree-id="m:opencode-fork"] .row-label')).toHaveText("Migrate Lean kernel");
  await expect(page.locator('[data-tree-id="m:codex-orig"]')).toHaveCount(0);

  const violations = await page.evaluate(() => (window as unknown as { __forkViolations: string[] }).__forkViolations);
  expect(violations).toEqual([]);
});
