import { expect, test } from "@playwright/test";
for (const theme of ["light", "dark"]) test(`controller board, skeleton geometry and keyboard focus in ${theme}`, async ({ page }) => {
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  let controller: string | null = "controller", status = "running", boardReads = 0;
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith("/boards")) { await route.fulfill({ status: 404 }); return; }
    let data: unknown = {};
    if (path === "/api/projects/notes") data = { slug: "notes", controller_mission_id: controller };
    else if (path.endsWith("/board")) { boardReads++; await pending; data = { text: "# Project board\nNext release: ship the desktop controller.\n".repeat(15), updated_at: "2026-11-15T10:00:00Z", controller_mission_id: controller }; }
    else if (path.endsWith("/controller-mission")) { controller = route.request().postDataJSON().mission_id; }
    else if (path.includes("/missions/controller")) data = { id: "controller", title: "Release planning", project: "notes", status, history: [] };
    await route.fulfill({ json: data });
  });
  await page.goto(`/tests/project-board.html?theme=${theme}`);
  await expect(page.getByRole("status", { name: "Loading board" })).toBeVisible();
  const board = page.locator(".project-board"), height = (await board.boundingBox())!.height;
  release(); await expect(board.locator("pre")).toContainText("Next release");
  expect((await board.boundingBox())!.height).toBe(height);
  await page.getByRole("button", { name: "Release planning" }).click(); await expect(page).toHaveTitle("controller");
  const input = page.getByRole("textbox", { name: "Message controller" });
  await input.focus();
  const focus = await input.evaluate(el => ({ shadow: getComputedStyle(el).boxShadow, outline: getComputedStyle(el).outlineStyle }));
  expect(focus.shadow).toBe("none"); expect(focus.outline).toBe("none");
  status = "completed"; await page.getByRole("button", { name: "Status changed" }).click(); await expect(page.getByText("completed", { exact: true })).toBeVisible();
  await expect.poll(() => boardReads).toBe(2);
  await page.getByRole("button", { name: "Clear", exact: true }).click(); await expect(page.getByText("No controller", { exact: true })).toBeVisible();
  await expect(input).toBeDisabled();
  await page.screenshot({ path: `test-results/project-board-${theme}.png`, fullPage: true });
});

test.skip("mission board survives a project move", async ({ page }) => {
  // This fixture server changes the board exactly as an MCP write would; the
  // browser only performs the real move action and never writes board REST.
  let project = "notes";
  const text = "# Mission plan\nKeep this text through the move.\n";
  const hash = "fixture-mission-board-sha256";
  await page.route("**/api/**", async route => {
    const request = route.request(), path = new URL(request.url()).pathname;
    if (path === "/api/projects/notes") return route.fulfill({ json: { slug: "notes", controller_mission_id: null } });
    if (path === "/api/projects/notes/boards" || path === "/api/projects/next/boards") {
      return route.fulfill({ json: { project, boards: project === "next" ? [{ mission_id: "controller", title: "Release planning", status: "active", parent_mission_id: null, updated_at: "2026-11-16T10:00:00Z", bytes: text.length, text_sha256: hash }] : [] } });
    }
    if (path === "/api/control/missions/controller/board") return route.fulfill({ json: { mission_id: "controller", text, updated_at: "2026-11-16T10:00:00Z", updated_by_mission_id: "controller", text_sha256: hash } });
    if (path === "/api/control/missions/move" && request.method() === "POST") { project = "next"; return route.fulfill({ json: { moved: [{ mission_id: "controller", project, folder: "", placement_revision: 2 }] } }); }
    if (path.includes("/missions/controller")) return route.fulfill({ json: { id: "controller", title: "Release planning", project, status: "active", history: [] } });
    return route.fulfill({ json: {} });
  });
  await page.goto("/tests/project-board.html?theme=light");
  await page.evaluate(() => fetch("/api/control/missions/move", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ mission_ids: ["controller"], project: "next" }) }));
  await page.reload();
  await expect(page.locator("body")).toContainText("Mission plan");
  await expect(page.locator("[data-text-sha256='fixture-mission-board-sha256']")).toHaveCount(0);
});
