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
  await expect(page.getByRole("menuitem", { name: "Resolve…" })).toBeVisible();
  await expect(page.getByRole("menuitem", { name: /Delete/ })).toBeVisible();
  await page.keyboard.press("Escape");
  // Old copies live in one collapsed section at the bottom, not in the list.
  await expect(catalog.locator('.skills-catalog-card [data-skill="spark-lean-offload"]').first()).toBeHidden();
  const oldCopies = page.locator("details.skills-oldcopies");
  await expect(oldCopies.locator("summary")).toContainText("Old copies (1)");
  await oldCopies.locator("summary").click();
  await expect(oldCopies.locator('[data-skill="spark-lean-offload"]')).toContainText("Import");
  // The page scrolls; the list has no scroll box of its own.
  expect(await page.locator(".skills-catalog-card").first().evaluate(el => getComputedStyle(el).overflowY)).not.toBe("auto");
  await expect(catalog.locator(".skills-origin-tag, .skills-aud")).toHaveCount(0);

  // One "Needs attention" filter.
  const attention = catalog.getByRole("button", { name: /Needs attention/ });
  await attention.click();
  await expect(catalog.locator(".skills-item[data-skill]").filter({ hasNot: page.locator(".skills-badge") })).toHaveCount(0);
  await attention.click();
  await expect(catalog).toContainText("aristotle-lean");
  await page.screenshot({ path: "test-results/skills-settings-dark.png" });

  // Drift is fixed without a button once the Library is loaded.
  await expect(page.locator("details.skills-advanced > summary")).toHaveText(/^Advanced/);
  await page.locator("details.skills-advanced > summary").click();
  const agyRow = page.getByRole("region", { name: "Harness compatibility" }).locator('details[data-harness="antigravity"]');
  await expect(agyRow).toContainText("Synced · 37 skills");
  const delivery = page.getByRole("region", { name: "Skill delivery preview" });
  await delivery.getByLabel("Preview project").selectOption("erdos-647");
  await expect(delivery).toContainText("Resolved delivery (4)");

  await page.evaluate(() => { document.documentElement.dataset.theme = "light"; document.querySelector(".s-body")?.scrollTo(0, 0); });
  await page.screenshot({ path: "test-results/skills-settings-light.png" });
});
