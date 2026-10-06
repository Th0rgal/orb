import {eventPage} from "./eventPageFixture";
import { test, expect } from "@playwright/test";

for (const target of [{ backend: "opencode", name: "OpenCode", model: "builtin/smart", label: "Smart (Default)" }, { backend: "antigravity", name: "Antigravity CLI", model: "node-argon", label: "Node Argon" }]) {
test(`fork dialog uses ${target.name} on the source destination without mutating it`, async ({ page }) => {
  const source = { id: "original", title: "Original work", status: "active", backend: "grok", model_override: "grok-4.6", project: "test", remote_node_id: "dgx-spark", history: [], created_at: "", updated_at: "" };
  const fork = { ...source, id: "forked", title: "Original work · fork", backend: target.backend, model_override: target.model };
  let created = false;
  const mutations: { path: string; body: any }[] = [];
  await page.addInitScript(() => { localStorage.setItem("orb.apiUrl", location.origin); localStorage.setItem("orb.jwt", "test"); localStorage.setItem("orb-theme", "dark"); });
  await page.route("**/api/**", async route => {
    const req = route.request(), path = new URL(req.url()).pathname;
    if(path === "/api/providers/antigravity-models") return route.fulfill({json:[new URL(req.url()).searchParams.get("node_id") === "dgx-spark" ? ["node-argon", "Node Argon"] : ["core-only", "Core Only"]]});
    if(path === "/api/model-routing/chains") return route.fulfill({json:[{id:"builtin/smart",name:"Smart (Default)"}]});
    if (req.method() !== "GET") {
      mutations.push({ path, body: req.postDataJSON() });
      if (path === "/api/control/missions/original/fork") { created = true; return route.fulfill({ json: fork }); }
      return route.fulfill({ status: 400 });
    }
    if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
    const json = path === "/api/projects" ? { projects: [{ slug: "test", title: "Test" }] }
      : path === "/api/backends" ? [{ id: "grok", name: "Grok Build" }, { id: "opencode", name: "OpenCode" }, { id: "antigravity", name: "Antigravity" }]
      : path === "/api/providers/backend-models" ? { backends: { grok: [{ value: "grok-4.6", label: "Grok 4.6" }], opencode: [{ value: "qwen", label: "Qwen" }] } }
      : path === "/api/control/missions" || path.endsWith("/missions") ? created ? [source, fork] : [source]
      : path === "/api/control/missions/original" ? source
      : path === "/api/control/missions/forked" ? fork
      : path.endsWith("/events") || path.endsWith("/queue") ? []
      : path.endsWith("/crons") ? { jobs: [] }
      : path.endsWith("/files") ? { entries: [] }
      : path === "/api/remote-nodes" ? { nodes: [{ id: "dgx-spark", status: "online" }] }
      : { job: null, runs: [] };
    return route.fulfill(path.endsWith("/events")?eventPage(route,Array.isArray(json)?json:[]):{json});
  });
  await page.goto("/");
  await page.locator(".row.project .row-main", { hasText: "Test" }).click();
  await page.getByRole("button", { name: /Original work/ }).click();
  await page.getByRole("button", { name: "Fork conversation", exact: true }).click();
  const menu = page.getByRole("menu", { name: "Fork conversation", exact: true });
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
  await expect(page.locator(".row.agent.active")).toHaveCount(1);
  await expect(page.locator(".row.agent.active")).toContainText("Original work · fork");
  expect(mutations).toHaveLength(1);
  expect(mutations[0]).toMatchObject({ path: "/api/control/missions/original/fork", body: { backend: target.backend, model_override: target.model } });
  if (target.backend === "antigravity") expect(mutations[0].body.model_effort).toBe("high");
  await expect(page.locator(".row.agent", { hasText: "Original work" }).first()).toBeVisible();
});

}
