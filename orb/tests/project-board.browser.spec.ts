import { expect, test } from "@playwright/test";
for (const theme of ["light", "dark"]) test(`controller board, skeleton geometry and keyboard focus in ${theme}`, async ({ page }) => {
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  let controller: string | null = "controller", status = "running", boardReads = 0;
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname;
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
