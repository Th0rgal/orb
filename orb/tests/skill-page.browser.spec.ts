import { expect, test } from "@playwright/test";

// A skill opens like a project file: in place, with a breadcrumb, its files as a
// slim tree and the shared document editor at full width. No modal.
for (const theme of ["dark", "light"]) test(`skill page edits SKILL.md in place: ${theme}`, async ({ page }) => {
  await page.addInitScript((t) => { localStorage.setItem("orb.apiUrl", location.origin); localStorage.setItem("orb.jwt", "test"); localStorage.setItem("orb-theme", t); }, theme);
  let content = "---\nname: agent-browser\ndescription: Drive a real browser.\nmetadata:\n  sandboxed:\n    audience: [mission, local]\n---\n\n# Agent browser\n\nOpen a page, then read it.\n\n```bash\nagent-browser open https://example.com --wait-for networkidle --screenshot /tmp/page.png --viewport 1280x800\n```\n";
  const commits: string[] = [];
  await page.route("**/api/**", async (route) => {
    const req = route.request(), path = new URL(req.url()).pathname;
    if (path === "/api/library/skill") return route.fulfill({ json: [{ name: "agent-browser", description: "Drive a real browser.", path: "skill/agent-browser" }] });
    if (path === "/api/library/skill/agent-browser") {
      if (req.method() === "PUT") { content = req.postDataJSON().content; return route.fulfill({ body: "Skill saved successfully" }); }
      return route.fulfill({ json: { name: "agent-browser", path: "skill/agent-browser", content, files: [{ name: "selectors.md", path: "references/selectors.md", content: "# Selectors\n" }], references: ["references/selectors.md"] } });
    }
    if (path === "/api/library/commit") { commits.push(req.postDataJSON().message); return route.fulfill({ body: "Committed successfully" }); }
    if (path === "/api/library/push") return route.fulfill({ body: "Pushed successfully" });
    if (path === "/api/library/status") return route.fulfill({ json: { remote: "git@github.com:Th0rgal/sandboxed-library.git", branch: "main", clean: true, ahead: 0, behind: 0, modified_files: [], last_synced_at: Math.floor(Date.now() / 1000) - 60 } });
    return route.fulfill({ json: path === "/api/projects" ? { projects: [] } : path === "/api/control/missions" ? [] : [] });
  });
  await page.setViewportSize({ width: 1280, height: 860 });
  await page.goto("/");
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.locator('[data-settings-section="agents"]').click();
  await page.locator('[data-skill="agent-browser"] .skills-item-head').click();

  await expect(page.getByRole("navigation", { name: "Breadcrumb" })).toContainText("Skills›agent-browser");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByRole("tree", { name: "agent-browser files" })).toContainText("selectors.md");
  await expect(page.getByRole("heading", { name: "Agent browser" })).toBeVisible();
  // The editor takes the width next to the tree; code keeps the column's margins.
  const main = (await page.locator(".skill-main").boundingBox())!;
  expect(main.width).toBeGreaterThan(700);
  const code = (await page.locator(".skill-main pre").first().boundingBox())!;
  expect(code.x - main.x).toBeGreaterThanOrEqual(16);
  expect(main.x + main.width - (code.x + code.width)).toBeGreaterThanOrEqual(16);
  await page.screenshot({ path: `test-results/skill-page-${theme}.png` });

  // Settings in the strip; ⌘S saves to the repo.
  await page.getByRole("radio", { name: "Always" }).click();
  await page.keyboard.press("Meta+s");
  await expect(page.getByText("Saved to repo")).toBeVisible();
  expect(commits).toEqual(["skill: update agent-browser"]);
  expect(content).toContain("scope: global");

  // Actions live in the … menu; back returns to the list.
  await page.getByRole("button", { name: "Actions for agent-browser" }).click();
  await expect(page.getByRole("menuitem", { name: "History" })).toBeVisible();
  await expect(page.getByRole("menuitem", { name: /Delete/ })).toBeVisible();
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Back to Skills" }).click();
  await expect(page.locator('[data-skill="agent-browser"]')).toBeVisible();
});
