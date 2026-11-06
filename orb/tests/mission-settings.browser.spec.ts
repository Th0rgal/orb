import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
const out = process.env.ORB_SCREENSHOT_DIR;
const shot = async (page: import("@playwright/test").Page, name: string) => {
  if (!out) return;
  mkdirSync(out, { recursive: true });
  await page.screenshot({ path: `${out}/${name}.png` });
};

for (const theme of ["dark", "light"] as const) {
  test(`mission settings page shows forecast, pool, children and saves (${theme})`, async ({ page }) => {
    await page.setViewportSize({ width: 1100, height: 980 });
    await page.goto(`/tests/mission-settings.html?theme=${theme}`);
    await expect(page.getByRole("dialog")).toHaveCount(0);
    const view = page.getByRole("region", { name: "Mission settings" });
    await expect(view).toBeVisible();
    await expect(view.getByTestId("mission-forecast-card")).toContainText("~4h 16m runway left");
    await expect(view.getByRole("switch", { name: "Spending budget" })).toHaveAttribute("aria-checked", "true");
    await expect(view.getByText("$6.00 of $10")).toBeVisible();
    await expect(view.getByRole("table", { name: "Subagent budgets" })).toContainText("Sub-budget $2.00");
    await shot(page, `mission-settings-${theme}`);
    const amount = view.getByLabel("Amount (USD)");
    await amount.fill("12");
    await view.getByRole("button", { name: "Save budget" }).click();
    await expect(view.getByText("of $12")).toBeVisible();
    await expect(amount).toHaveValue("12");
  });
}

test("budget is off by default and turns on optimistically", async ({ page }) => {
  await page.goto(`/tests/mission-settings.html?mode=none&theme=dark`);
  const view = page.getByRole("region", { name: "Mission settings" });
  const toggle = view.getByRole("switch", { name: "Spending budget" });
  await expect(toggle).toHaveAttribute("aria-checked", "false");
  await expect(view.getByText("No budget. Only the daily managed-machine cap applies.")).toBeVisible();
  await expect(view.getByText("Uses the global limit (16 concurrent across Orb).")).toBeVisible();
  await expect(view.getByText("Unthrottled. Requests and spawns run at full speed.")).toBeVisible();
  await shot(page, "mission-settings-off");
  await toggle.click();
  // Before the 150 ms save resolves.
  await expect(toggle).toHaveAttribute("aria-checked", "true");
  await expect(view.getByLabel("Amount (USD)")).toHaveValue("5");
});

test("bandwidth pacing limits shape the forecast runway and save optimistically", async ({ page }) => {
  await page.setViewportSize({ width: 1100, height: 980 });
  await page.goto(`/tests/mission-settings.html?theme=dark`);
  const view = page.getByRole("region", { name: "Mission settings" });
  const bwSwitch = view.getByRole("switch", { name: "Bandwidth limit" });
  await expect(bwSwitch).toHaveAttribute("aria-checked", "false");

  await bwSwitch.click();
  await expect(bwSwitch).toHaveAttribute("aria-checked", "true");
  await view.getByLabel("Tokens per minute").fill("90k");
  await view.getByLabel("Compute per minute (vCPU)").fill("24");
  await view.getByLabel("Compute burn ceiling ($/h)").fill("0.75");

  // Forecast card updates live to show extended ~8h 32m runway.
  await expect(view.getByTestId("mission-forecast-card")).toContainText("~8h 32m runway left");
  await expect(view.getByTestId("mission-forecast-card")).toContainText("from bandwidth cap");

  await view.getByRole("button", { name: "Save bandwidth" }).click();
  await expect(view.getByText("90k tok/min · 24 vCPU/min · $0.75/h")).toBeVisible();
  await shot(page, "mission-settings-bandwidth");
});

test("machine limit overrides global cap with expandable per-provider limits and folded $0 subagents", async ({ page }) => {
  await page.setViewportSize({ width: 1100, height: 960 });
  await page.goto(`/tests/mission-settings.html?mode=none&crowd=1&theme=dark`);
  const view = page.getByRole("region", { name: "Mission settings" });
  await expect(view).toBeVisible();
  // Duplicate Subagent pool list is hidden when Budget, Bandwidth & Machine limit are off.
  await expect(view.getByRole("table", { name: "Subagent budgets" })).toHaveCount(0);
  // Stats folds the 10 $0 subagents and renders "Unknown model" instead of a blank cell.
  await expect(view.getByRole("table", { name: "Spend by served model" })).toContainText("Unknown model");
  const subagentSpend = view.getByRole("table", { name: "Subagent spend" });
  await expect(subagentSpend).toContainText("10 with $0 spend · show");

  // Turn on Machine limit and set Vast.ai = 2, boat.dev = 8.
  const limitSwitch = view.getByRole("switch", { name: "Machine limit" });
  await limitSwitch.click();
  await expect(limitSwitch).toHaveAttribute("aria-checked", "true");
  await view.getByRole("button", { name: /Per-provider limits/ }).click();
  await view.getByLabel("Max concurrent machines").fill("10");
  await view.getByLabel("Vast.ai limit").fill("2");
  await view.getByLabel("boat.dev limit").fill("8");
  await view.getByRole("button", { name: "Save limit" }).click();
  await expect(view.getByText("Vast.ai: 0 of 2")).toBeVisible();
  await expect(view.getByText("boat.dev: 0 of 8")).toBeVisible();

  // Expanding $0 subagent spend activates the inner scroll container instead of blowing up the page.
  await subagentSpend.getByRole("button", { name: /10 with \$0 spend/ }).click();
  await subagentSpend.getByRole("button", { name: /Show all 12/ }).click();
  await expect(subagentSpend.locator(".st-tbody-scroll")).toBeVisible();
  await shot(page, "mission-settings-vm-limits");
});

test("a refused save rolls back with Retry", async ({ page }) => {
  await page.goto(`/tests/mission-settings.html?refuse=1&theme=dark`);
  const view = page.getByRole("region", { name: "Mission settings" });
  await view.getByLabel("Amount (USD)").fill("50");
  await view.getByRole("button", { name: "Save budget" }).click();
  const alert = page.getByRole("alert");
  await expect(alert).toContainText("Budget not saved");
  await expect(view.getByLabel("Amount (USD)")).toHaveValue("10");
  await expect(alert.getByRole("button", { name: "Retry" })).toBeVisible();
  await shot(page, "mission-settings-error");
});

test("mission settings fits a 390px window without horizontal overflow", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 780 });
  await page.goto(`/tests/mission-settings.html?theme=dark`);
  const view = page.getByRole("region", { name: "Mission settings" });
  await expect(view).toBeVisible();
  const box = await view.boundingBox();
  expect(box!.width).toBeLessThanOrEqual(390);
  await shot(page, "mission-settings-390");
});

test("stats section: totals, served models, subagents, period toggle, and Resources & DAG navigation", async ({ page }) => {
  await page.setViewportSize({ width: 1100, height: 1300 });
  await page.goto(`/tests/mission-settings.html?theme=dark`);
  const view = page.getByRole("region", { name: "Mission settings" });
  const total = view.locator(".st-tile", { hasText: "Total" }).locator(".st-tile-value");
  await expect(total).toHaveText("$6.12");
  await expect(view.getByRole("table", { name: "Spend by served model" })).toContainText("antigravity/gemini-4-argon");
  await expect(view.getByRole("table", { name: "Subagent spend" })).toContainText("Audit lean-native");
  await shot(page, "mission-settings-stats");
  await view.getByRole("radio", { name: "Today" }).click();
  await expect(total).toHaveText("$1.40");

  await view.getByRole("button", { name: "Resources & DAG" }).click();
  await expect(page.getByTestId("opened-route")).toHaveText("rm:root");
});
