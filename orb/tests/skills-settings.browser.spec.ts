import { expect, test } from "@playwright/test";

test.use({ browserName: "webkit", viewport: { width: 1120, height: 960 } });

test("skills settings displays harness matrix, resolves drift with one click, and previews skills in dark and light mode", async ({
  page,
}) => {
  await page.goto("/tests/skills-settings.html");

  const compatSection = page.getByRole("region", { name: "Harness compatibility" });
  await expect(compatSection).toBeVisible();

  const agyRow = compatSection.locator('details[data-harness="antigravity"]');
  await expect(agyRow).toContainText("Out of sync · 2/37");

  // Expand Antigravity row to inspect missing skills
  await agyRow.locator("summary").click();
  await expect(agyRow).toContainText("Missing 5 canonical skills in ~/.agents/skills");
  await expect(agyRow.locator(".skills-mini-chip").first()).toBeVisible();

  // Expand a skill in the catalog to preview SKILL.md
  const catalogSection = page.getByRole("region", { name: "Global and Library skills catalog" });
  const policyItem = catalogSection.locator('[data-skill="controllers-policy"]');
  await policyItem.getByRole("button").first().click();
  await expect(policyItem.locator(".skills-md-preview")).toContainText("STATE_SIGNATURE");

  // Verify project skills section
  const projectSection = page.getByRole("region", { name: "Project skills" });
  await expect(projectSection).toContainText("Erdos 647 Formalization");
  await expect(projectSection).toContainText("aristotle-lean");

  await page.evaluate(() => {
    document.querySelector(".s-body")?.scrollTo(0, 0);
  });
  await page.screenshot({ path: "test-results/skills-settings-dark.png" });

  await page.evaluate(() => {
    const el = document.querySelector(".s-body");
    if (el) el.scrollTo(0, el.scrollHeight);
  });
  await page.screenshot({ path: "test-results/skills-settings-dark-bottom.png" });

  await page.evaluate(() => {
    document.querySelector(".s-body")?.scrollTo(0, 0);
  });

  // Click Sync all harnesses and verify drift is resolved
  const syncBtn = page.getByRole("button", { name: /Sync all harnesses \(2 drifted\)/ });
  await syncBtn.click();
  await expect(page.getByRole("status")).toContainText(
    "Synchronized 37 skills across all 5 local harness directories",
  );
  await expect(agyRow).toContainText("Synced · 37 skills");

  // Switch to light mode and capture screenshot
  await page.evaluate(() => {
    document.documentElement.dataset.theme = "light";
    document.querySelector(".s-body")?.scrollTo(0, 0);
  });
  await page.screenshot({ path: "test-results/skills-settings-light.png" });
});
