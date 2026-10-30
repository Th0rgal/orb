import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
const out = process.env.ORB_SCREENSHOT_DIR;
const shot = async (page: import("@playwright/test").Page, name: string) => {
  if (!out) return;
  mkdirSync(out, { recursive: true });
  await page.screenshot({ path: `${out}/${name}.png` });
};

for (const theme of ["dark", "light"] as const) {
  test(`mission settings sheet shows the pool, children and saves (${theme})`, async ({ page }) => {
    await page.goto(`/tests/mission-settings.html?theme=${theme}`);
    const dialog = page.getByRole("dialog", { name: "Mission settings" });
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole("switch", { name: "Spending budget" })).toHaveAttribute("aria-checked", "true");
    await expect(dialog.getByText("$6.00 of $10")).toBeVisible();
    await expect(dialog.getByRole("table", { name: "Subagent budgets" })).toContainText("Sub-budget $2.00");
    await shot(page, `mission-settings-${theme}`);
    const amount = dialog.getByLabel("Amount (USD)");
    await amount.fill("12");
    await dialog.getByRole("button", { name: "Save budget" }).click();
    await expect(dialog.getByText("of $12")).toBeVisible();
    await expect(amount).toHaveValue("12");
  });
}

test("budget is off by default and turns on optimistically", async ({ page }) => {
  await page.goto(`/tests/mission-settings.html?mode=none&theme=dark`);
  const dialog = page.getByRole("dialog", { name: "Mission settings" });
  const toggle = dialog.getByRole("switch", { name: "Spending budget" });
  await expect(toggle).toHaveAttribute("aria-checked", "false");
  await expect(dialog.getByText("No budget. Only the daily managed-machine cap applies.")).toBeVisible();
  await expect(dialog.getByText("Uses the global limit (16 concurrent across Orb).")).toBeVisible();
  await shot(page, "mission-settings-off");
  await toggle.click();
  // Before the 150 ms save resolves.
  await expect(toggle).toHaveAttribute("aria-checked", "true");
  await expect(dialog.getByLabel("Amount (USD)")).toHaveValue("5");
});

test("machine limit overrides global cap with expandable per-provider limits and folded $0 subagents", async ({ page }) => {
  await page.setViewportSize({ width: 1100, height: 960 });
  await page.goto(`/tests/mission-settings.html?mode=none&crowd=1&theme=dark`);
  const dialog = page.getByRole("dialog", { name: "Mission settings" });
  await expect(dialog).toBeVisible();
  // Duplicate Subagent pool list is hidden when both Budget and Machine limit are off.
  await expect(dialog.getByRole("table", { name: "Subagent budgets" })).toHaveCount(0);
  // Stats folds the 10 $0 subagents and renders "Unknown model" instead of a blank cell.
  await expect(dialog.getByRole("table", { name: "Spend by served model" })).toContainText("Unknown model");
  const subagentSpend = dialog.getByRole("table", { name: "Subagent spend" });
  await expect(subagentSpend).toContainText("10 with $0 spend · show");

  // Turn on Machine limit and set Vast.ai = 2, boat.dev = 8.
  const limitSwitch = dialog.getByRole("switch", { name: "Machine limit" });
  await limitSwitch.click();
  await expect(limitSwitch).toHaveAttribute("aria-checked", "true");
  await dialog.getByRole("button", { name: /Per-provider limits/ }).click();
  await dialog.getByLabel("Max concurrent machines").fill("10");
  await dialog.getByLabel("Vast.ai limit").fill("2");
  await dialog.getByLabel("boat.dev limit").fill("8");
  await dialog.getByRole("button", { name: "Save limit" }).click();
  await expect(dialog.getByText("Vast.ai: 0 of 2")).toBeVisible();
  await expect(dialog.getByText("boat.dev: 0 of 8")).toBeVisible();

  // Expanding $0 subagent spend activates the inner scroll container instead of blowing up the sheet.
  await subagentSpend.getByRole("button", { name: /10 with \$0 spend/ }).click();
  await subagentSpend.getByRole("button", { name: /Show all 12/ }).click();
  await expect(subagentSpend.locator(".st-tbody-scroll")).toBeVisible();
  await shot(page, "mission-settings-vm-limits");
});

test("a refused save rolls back with Retry", async ({ page }) => {
  await page.goto(`/tests/mission-settings.html?refuse=1&theme=dark`);
  const dialog = page.getByRole("dialog", { name: "Mission settings" });
  await dialog.getByLabel("Amount (USD)").fill("50");
  await dialog.getByRole("button", { name: "Save budget" }).click();
  await expect(dialog.getByText("Budget not saved")).toBeVisible();
  await expect(dialog.getByLabel("Amount (USD)")).toHaveValue("10");
  await expect(dialog.getByRole("button", { name: "Retry" })).toBeVisible();
  await shot(page, "mission-settings-error");
});

test("mission settings fits a 390px window", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 780 });
  await page.goto(`/tests/mission-settings.html?theme=dark`);
  const dialog = page.getByRole("dialog", { name: "Mission settings" });
  await expect(dialog).toBeVisible();
  const box = await dialog.boundingBox();
  expect(box!.width).toBeLessThanOrEqual(390);
  await shot(page, "mission-settings-390");
});

test("stats section: totals, served models, subagents, period toggle", async ({ page }) => {
  await page.setViewportSize({ width: 1100, height: 1300 });
  await page.goto(`/tests/mission-settings.html?theme=dark`);
  const dialog = page.getByRole("dialog", { name: "Mission settings" });
  const total = dialog.locator(".st-tile", { hasText: "Total" }).locator(".st-tile-value");
  await expect(total).toHaveText("$6.12");
  await expect(dialog.getByRole("table", { name: "Spend by served model" })).toContainText("antigravity/gemini-4-argon");
  await expect(dialog.getByRole("table", { name: "Subagent spend" })).toContainText("Audit lean-native");
  await shot(page, "mission-settings-stats");
  await dialog.getByRole("radio", { name: "Today" }).click();
  await expect(total).toHaveText("$1.40");
});
