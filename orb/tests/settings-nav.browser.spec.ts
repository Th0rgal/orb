import { expect, test, type Page } from "@playwright/test";
import { privilegeSnapshot } from "./privilegeAccessFixture";

async function setup(page: Page, selected?: string) {
  await page.addInitScript((sel: string | null) => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    if (sel) localStorage.setItem("orb.selectedConversation", sel);
  }, selected ?? null);
  await page.route("**/api/**", (route) => {
    const path = new URL(route.request().url()).pathname;
    const json =
      path === "/api/privilege-access" ? privilegeSnapshot(2)
      : path === "/api/ai/providers" ? [{ id: "claude", name: "Claude (work)", provider_type: "anthropic", enabled: true, status: { type: "connected" } }]
      : path === "/api/ai/providers/usage" ? { entries: { claude: { provider_type: "anthropic", unified_5h_utilization: 1, unified_7d_utilization: 0.4 } } }
      : path === "/api/projects" ? { projects: [] }
      : path === "/api/control/missions" ? []
      : { job: null, runs: [] };
    return route.fulfill({ json });
  });
  await page.goto("/");
  await expect(page.getByRole("button", { name: "Settings", exact: true })).toBeVisible();
}

const title = (page: Page) => page.locator(".settings-page > .s-inner > h2");

test("settings has five sections with subtitles, tabs and attention dots", async ({ page }) => {
  await setup(page);
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  const rows = page.locator("[data-settings-section]");
  await expect(rows.locator(".row-label")).toHaveText(["Account", "Models", "Agents", "Security", "Notifications"]);
  await expect(title(page)).toHaveText("Account");
  await expect(page.locator(".settings-subtitle")).toHaveText("Your server connection, connected accounts, how Orb looks and usage telemetry.");

  // Bunker Mode is active and a provider quota is spent.
  await expect(page.locator('[data-settings-section="security"] .row-dot')).toBeVisible();
  await expect(page.locator('[data-settings-section="models"] .row-dot')).toBeVisible();
  await expect(page.locator('[data-settings-section="account"] .row-dot')).toHaveCount(0);

  await rows.filter({ hasText: "Models" }).click();
  await expect(title(page)).toHaveText("Models");
  // Quotas live in Providers only; Models has no quota strip.
  await expect(page.locator(".quota-strip")).toHaveCount(0);
  await expect(page.getByRole("tab")).toHaveText(["Fallback Chains", "Providers", "Usage", "API Keys"]);

  // Agents tabs move with the arrow keys and keep focus.
  await rows.filter({ hasText: "Agents" }).click();
  const tab = page.getByRole("tab", { name: "Skills" });
  await expect(tab).toHaveAttribute("aria-selected", "true");
  await tab.focus();
  await page.keyboard.press("ArrowRight");
  await expect(page.getByRole("tab", { name: "Assistant" })).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("tab", { name: "Assistant" })).toBeFocused();

  await rows.filter({ hasText: "Security" }).click();
  await expect(title(page)).toHaveText("Security");
  await expect(page.getByTestId("bunker-mode-card")).toBeVisible();
  await expect(page.getByTestId("bunker-exit-btn")).toBeVisible();
});

for (const [id, section, tab] of [
  ["routing", "Models", "Fallback Chains"],
  ["usage-settings", "Models", "Usage"],
  ["routing-keys", "Models", "API Keys"],
  ["hermes-settings", "Agents", "Assistant"],
  ["btw-settings", "Agents", "Quick questions (/btw)"],
  ["skills-settings", "Agents", "Skills"],
  ["execution", "Agents", "Local agents"],
  ["bitwarden-settings", "Security", "Secrets vault"],
] as [string, string, string | null][]) {
  test(`old page id ${id} opens ${section}${tab ? ` → ${tab}` : ""}`, async ({ page }) => {
    await setup(page);
    await page.evaluate((target) => window.dispatchEvent(new CustomEvent("orb:open-page", { detail: target })), id);
    await expect(title(page)).toHaveText(section);
    await expect(page.locator(`[data-settings-section][aria-current="page"] .row-label`)).toHaveText(section);
    if (tab) await expect(page.getByRole("tab", { name: tab, exact: true })).toHaveAttribute("aria-selected", "true");
  });
}

test("a saved old page id reopens in its new section", async ({ page }) => {
  await setup(page, "execution");
  await expect(title(page)).toHaveText("Agents");
  await expect(page.getByRole("tab", { name: "Local agents" })).toHaveAttribute("aria-selected", "true");
});

test("Providers links to usage history, which opens the Models › Usage tab", async ({ page }) => {
  await setup(page);
  await page.getByRole("button", { name: "Providers", exact: true }).click();
  await page.getByRole("button", { name: "Usage history", exact: true }).click();
  await expect(title(page)).toHaveText("Models");
  await expect(page.locator('[data-settings-section="models"]')).toHaveAttribute("aria-current", "page");
});
