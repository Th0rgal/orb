import { expect, test } from "@playwright/test";

test.use({ browserName: "webkit", viewport: { width: 1120, height: 960 } });

test("skills pane: one repo line, one badge per row, attention filter, automatic sync, editor controls", async ({ page }) => {
  await page.goto("/tests/skills-settings.html");

  const catalog = page.getByRole("region", { name: "Library skills" });
  await expect(catalog).toContainText("Th0rgal/sandboxed-library");
  await expect(catalog).toContainText("synced 2m ago");
  await expect(page.getByRole("button", { name: /Sync all harnesses/ })).toHaveCount(0);

  // One badge per row, only when unusual; its actions live in the row's menu.
  const policy = catalog.locator('[data-skill="controllers-policy"]');
  await expect(policy.locator(".skills-badge")).toHaveText(["Edited on this Mac"]);
  await expect(policy.getByRole("button", { name: /Keep|Discard/ })).toHaveCount(0);
  await policy.getByRole("button", { name: "Actions for controllers-policy" }).click();
  await expect(page.getByRole("menuitem", { name: "Keep this Mac’s version" })).toBeVisible();
  await expect(page.getByRole("menuitem", { name: "Discard this Mac’s edit" })).toBeVisible();
  await expect(page.getByRole("menuitem", { name: /Delete/ })).toBeVisible();
  await page.keyboard.press("Escape");
  const legacy = catalog.locator('[data-skill="spark-lean-offload"]');
  await expect(legacy.locator(".skills-badge")).toHaveText(["Only in an old folder"]);
  await legacy.click({ button: "right" });
  await expect(page.getByRole("menuitem", { name: "Import to the Library" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(catalog.locator(".skills-origin-tag, .skills-aud")).toHaveCount(0);

  // One "Needs attention" filter.
  const attention = catalog.getByRole("button", { name: /Needs attention/ });
  await attention.click();
  await expect(catalog.locator(".skills-item[data-skill]").filter({ hasNot: page.locator(".skills-badge") })).toHaveCount(0);
  await attention.click();
  await expect(catalog).toContainText("aristotle-lean");
  await page.screenshot({ path: "test-results/skills-settings-dark.png" });

  // Drift is fixed without a button once the Library is loaded.
  await page.locator("details.skills-advanced > summary").click();
  const agyRow = page.getByRole("region", { name: "Harness compatibility" }).locator('details[data-harness="antigravity"]');
  await expect(agyRow).toContainText("Synced · 37 skills");
  const delivery = page.getByRole("region", { name: "Skill delivery preview" });
  await delivery.getByLabel("Preview project").selectOption("erdos-647");
  await expect(delivery).toContainText("Resolved delivery (4)");

  // One panel: the skill's files as a tree, the open file on the right.
  await policy.locator(".skills-item-head").click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByRole("tree", { name: "controllers-policy files" })).toBeVisible();
  await expect(dialog.locator(".skills-version, .skills-diff")).toHaveCount(0);
  await expect(dialog.locator(".skills-oldcopy")).toContainText("Old copy in");
  // Opens on the rendered markdown; Edit shows the source.
  await expect(dialog.locator(".skills-md-view")).toContainText("STATE_SIGNATURE");
  await expect(dialog.getByRole("button", { name: "Edit" })).toBeVisible();
  await expect(dialog.getByRole("group", { name: "Who uses it" }).getByRole("checkbox")).toHaveCount(3);
  await expect(dialog.getByRole("radio", { name: "Always" })).toHaveAttribute("aria-checked", "true");
  await expect(dialog.getByRole("button", { name: "History" })).toBeVisible();
  // Nothing touches the panel edges.
  const box = (await dialog.boundingBox())!, body = (await dialog.locator(".skills-panel").boundingBox())!;
  expect(body.x - box.x).toBeGreaterThanOrEqual(16);
  expect(box.x + box.width - (body.x + body.width)).toBeGreaterThanOrEqual(16);
  // Delete confirms inside the panel, never as a dialog on top.
  await dialog.getByRole("button", { name: "Delete…" }).click();
  await expect(page.getByRole("dialog")).toHaveCount(1);
  await expect(dialog.getByRole("alertdialog", { name: "Delete controllers-policy?" })).toBeVisible();
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await page.waitForTimeout(250);
  await page.screenshot({ path: "test-results/skills-detail-dark.png" });
  await dialog.getByRole("button", { name: "Close", exact: true }).first().click();

  await page.evaluate(() => { document.documentElement.dataset.theme = "light"; document.querySelector(".s-body")?.scrollTo(0, 0); });
  await page.screenshot({ path: "test-results/skills-settings-light.png" });
});
