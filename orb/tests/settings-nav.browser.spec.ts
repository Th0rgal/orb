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
  ["inbox-summaries", "Agents", "Inbox & summaries"],
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

test("Inference links to usage history, which opens the Models › Usage tab", async ({ page }) => {
  await setup(page);
  await page.getByRole("button", { name: "Inference", exact: true }).click();
  await page.getByRole("button", { name: "Usage history", exact: true }).click();
  await expect(title(page)).toHaveText("Models");
  await expect(page.locator('[data-settings-section="models"]')).toHaveAttribute("aria-current", "page");
});

test("opening and leaving Settings preserves loaded sidebar projects and expanded state without reloading", async ({ page }) => {
  let projectsCalls = 0;
  let projectMissionsCalls = 0;
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
  });
  await page.route("**/api/**", (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname;
    if (path === "/api/projects") {
      projectsCalls += 1;
      return route.fulfill({
        json: {
          projects: [
            { slug: "omarchnix", title: "Omarchnix", status: "active", updated_at: "2026-11-09T15:00:00Z" },
          ],
        },
      });
    }
    if (path === "/api/control/missions" && url.searchParams.get("project") === "omarchnix") {
      projectMissionsCalls += 1;
      return route.fulfill({
        json: [
          {
            id: "m-omarch-1",
            title: "Please fix the repo commit push and merge",
            project: "omarchnix",
            status: "paused",
            created_at: "2026-11-09T15:00:00Z",
            updated_at: "2026-11-09T15:05:00Z",
          },
        ],
      });
    }
    const json =
      path === "/api/privilege-access" ? privilegeSnapshot(0)
      : path === "/api/ai/providers" ? []
      : path === "/api/ai/providers/usage" ? { entries: {} }
      : path === "/api/control/missions" ? []
      : { job: null, runs: [] };
    return route.fulfill({ json });
  });

  await page.goto("/");
  const projectBtn = page.locator('[data-project-navigation]').getByRole("button", { name: "Omarchnix", exact: true });
  await expect(projectBtn).toBeVisible();
  await projectBtn.click();
  await expect(page.locator('[data-project-navigation]').getByText("Please fix the repo commit push and merge")).toBeVisible();

  const projectsCallsBeforeSettings = projectsCalls;
  const missionsCallsBeforeSettings = projectMissionsCalls;

  // Open Settings, switch tabs, and return via Back:
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await expect(title(page)).toHaveText("Account");
  await expect(projectBtn).toBeHidden();

  await page.locator('[data-settings-section="models"]').click();
  await expect(title(page)).toHaveText("Models");

  await page.locator("button.settings-back").click();

  // Sidebar project and its expanded conversation remain immediately visible with zero reload or empty-state flash:
  await expect(projectBtn).toBeVisible();
  await expect(page.locator('[data-project-navigation]').getByText("Please fix the repo commit push and merge")).toBeVisible();
  await expect(page.locator(".sb-scroll")).not.toContainText("No projects on the core backend.");
  expect(projectsCalls).toBe(projectsCallsBeforeSettings);
  expect(projectMissionsCalls).toBe(missionsCallsBeforeSettings);
});
