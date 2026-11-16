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

for (const theme of ["light", "dark"]) test.describe(theme, () => {
test("mission board survives a project move", async ({ page }) => {
  // This fixture server changes the board exactly as an MCP write would; the
  // browser only performs the real move action and never writes board REST.
  let project = "notes";
  const text = "# Mission plan\nKeep this text through the move.\n";
  const hash = "fixture-mission-board-sha256";
  await page.addInitScript(theme => { localStorage.setItem("orb.apiUrl", location.origin); localStorage.setItem("orb.jwt", "test"); localStorage.setItem("orb.theme", theme); }, theme);
  const mission = () => ({ id: "controller", title: "Release planning", project, placement_revision: project === "notes" ? 1 : 2, status: "completed", backend: "opencode", tags: [], history: [], updated_at: "2026-11-16T10:00:00Z" });
  await page.route("**/api/**", async route => {
    const request = route.request(), path = new URL(request.url()).pathname;
    if (path === "/api/projects") return route.fulfill({ json: { projects: [{ slug: "notes", title: "Notes" }, { slug: "next", title: "Next" }] } });
    if (path === "/api/projects/notes" || path === "/api/projects/next") return route.fulfill({ json: { slug: path.split("/")[3], controller_mission_id: null } });
    if (path === "/api/projects/notes/boards" || path === "/api/projects/next/boards") {
      return route.fulfill({ json: { project: path.split("/")[3], boards: project === path.split("/")[3] ? [{ mission_id: "controller", title: "Release planning", status: "active", parent_mission_id: null, updated_at: "2026-11-16T10:00:00Z", bytes: text.length, text_sha256: hash }] : [] } });
    }
    if (path === "/api/control/missions/controller/board") return route.fulfill({ json: { mission_id: "controller", text, updated_at: "2026-11-16T10:00:00Z", updated_by_mission_id: "controller", text_sha256: hash } });
    if (path === "/api/control/missions/move" && request.method() === "POST") { project = "next"; return route.fulfill({ json: { moved: [{ mission_id: "controller", project, folder: "", placement_revision: 2 }] } }); }
    if (path === "/api/control/missions") return route.fulfill({ json: [mission()] });
    if (path.includes("/missions/controller")) return route.fulfill({ json: mission() });
    if (path.endsWith("/files")) return route.fulfill({ json: { entries: [] } });
    return route.fulfill({ json: [] });
  });
  await page.goto("/");
  const tree = page.getByRole("tree", { name: "Projects", exact: true });
  await tree.getByRole("button", { name: "Notes", exact: true }).click();
  const row = tree.getByRole("button", { name: "Release planning", exact: true });
  await row.click();
  await page.locator(".mission-board-disclosure > summary").click();
  await expect(page.getByTestId("mission-board").locator("pre")).toHaveText(text);
  await row.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Move", exact: true }).click();
  await tree.getByRole("button", { name: "Next", exact: true }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Move here", exact: true }).click();
  await expect.poll(() => project).toBe("next");
  await expect(page.getByTestId("mission-board").locator("pre")).toHaveText(text);
  await expect(page.getByTestId("mission-board")).toHaveAttribute("data-text-sha256", hash);
});
});
