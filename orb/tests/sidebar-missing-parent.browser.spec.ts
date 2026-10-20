import { expect, test } from "@playwright/test";

const P = "52bbf658-8705-4df7-8510-24dc69aed102";
const at = (minute: number) => new Date(Date.UTC(2026, 9, 20, 0, minute)).toISOString();
const mission = (id: string, title: string, minute: number, parent: string | null) => ({ id, title, status: "active", project: "assistant", tags: [], history: [], parent_mission_id: parent, created_at: at(minute), updated_at: at(minute) });

test("a parent with 150 newer children shows as one parent row with collapsible children", async ({ page }) => {
  await page.addInitScript(() => { localStorage.setItem("orb.apiUrl", location.origin); localStorage.setItem("orb.jwt", "test"); });
  const parent = mission(P, "Autoresearch-archi", 0, null);
  const children = Array.from({ length: 150 }, (_, i) => mission(`w-${i}`, `Wave 5 W5_${i}`, 300 - i, P));
  await page.route("**/api/**", route => {
    const url = new URL(route.request().url()), path = url.pathname;
    const limit = Number(url.searchParams.get("limit") ?? 50);
    const json = path === "/api/projects" ? { projects: [{ slug: "assistant", title: "Assistant" }] }
      : path === `/api/control/missions/${P}` ? parent
      : path.startsWith("/api/control/missions/") ? undefined
      // Newest first, like Core: the page holds only children.
      : path === "/api/control/missions" ? [...children, parent].slice(0, limit)
      : path.endsWith("/files") ? { entries: [] }
      : path.endsWith("/crons") ? { jobs: [] }
      : path.endsWith("/controller") ? { job: null, runs: [] }
      : {};
    return json === undefined ? route.fulfill({ status: 404, json: { error: "not found" } }) : route.fulfill({ json });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Assistant", exact: true }).click();
  await expect(page.getByRole("button", { name: /Autoresearch-archi/ }).first()).toBeVisible();
  // Children are inside the closed parent, not at the project root.
  await expect(page.getByText("Wave 5 W5_0", { exact: true })).toHaveCount(0);
  const toggle = page.getByRole("button", { name: /Show the \d+ missions launched by Autoresearch-archi/ });
  await toggle.click();
  await expect(page.getByText("Wave 5 W5_0", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: /Hide the \d+ missions launched by Autoresearch-archi/ }).click();
  await expect(page.getByText("Wave 5 W5_0", { exact: true })).toHaveCount(0);
});
