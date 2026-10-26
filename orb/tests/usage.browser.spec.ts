import { expect, test } from "@playwright/test";

const t = (requests: number, cost_cents: number, unknown = 0) => ({ requests, input_tokens: requests * 8000, output_tokens: requests * 400, cache_creation_tokens: 0, cache_read_tokens: 0, cost_cents, unknown_cost_requests: unknown });

test("Usage details (from Providers) shows router attribution over a selectable window", async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
  });
  const windows: string[] = [];
  await page.route("**/api/**", route => {
    const url = new URL(route.request().url());
    if (url.pathname !== "/api/ai/usage/summary") return route.fulfill({ json: url.pathname === "/api/projects" ? { projects: [] } : [] });
    const window = url.searchParams.get("window")!;
    windows.push(url.search);
    const hour = new Date(); hour.setUTCMinutes(0, 0, 0);
    const key = hour.toISOString().slice(0, 13);
    return route.fulfill({ json: {
      window, since: null, cost_status: "partial", totals: t(254, 520, 4),
      by_model: [
        { model: "gemini-4-argon", provider: "google", source: "router", cost_status: "known", ...t(250, 520) },
        { model: "mystery-model", provider: null, source: "router", cost_status: "unknown", ...t(4, 0, 4) },
      ],
      by_provider: [{ key: "google", label: null, cost_status: "known", ...t(250, 520) }],
      by_source: [{ key: "router", label: null, cost_status: "partial", ...t(254, 520, 4) }],
      by_backend: [], by_mission: [], by_account: [],
      by_api_key: [{ key: "key-argon", label: "Nightly bot", cost_status: "known", ...t(250, 520) }],
      by_day: [{ day: key.slice(0, 10), router_requests: 254, ...t(254, 520, 4) }],
      by_hour: [{ hour: key, router_requests: 254, ...t(254, 520, 4) }],
    } });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Providers", exact: true }).click();
  await page.getByRole("button", { name: "Usage details", exact: true }).click();
  await expect(page.getByRole("table", { name: "Usage by model" })).toContainText("gemini-4-argon");
  await expect(page.getByRole("table", { name: "Usage by model" })).toContainText("Unknown");
  await expect(page.getByText("100%", { exact: true })).toBeVisible();
  await expect(page.locator(".usage-chart rect.usage-bar.router")).toHaveCount(1);
  await expect(page.locator(".usage-chart .usage-bar:not(.router)")).toHaveCount(24);

  await page.getByLabel("Time window").selectOption("5h");
  await expect.poll(() => windows.at(-1)).toBe("?window=5h");
  await expect(page.locator(".usage-chart .usage-bar:not(.router)")).toHaveCount(5);

  await page.getByLabel("Group by").selectOption("api_key");
  await page.getByRole("button", { name: "Nightly bot" }).click();
  await expect.poll(() => windows).toContain("?window=5h&api_key=key-argon");
  await expect(page.getByRole("button", { name: "Clear api_key filter" })).toBeVisible();
  // The page stays inside narrow settings without horizontal overflow.
  await page.setViewportSize({ width: 560, height: 800 });
  const overflow = await page.locator(".usage-page").evaluate(el => el.scrollWidth - el.clientWidth);
  expect(overflow).toBeLessThanOrEqual(1);
});
