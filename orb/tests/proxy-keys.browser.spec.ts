import { expect, test } from "@playwright/test";

test("manages proxy keys in Routing and fits narrow settings", async ({ page }) => {
  let keys = [
    { id: "cursor", name: "Cursor", key_prefix: "sk-proxy-ab12", created_at: "2026-09-01T00:00:00Z", last_used_at: "2026-10-08T12:00:00Z" },
    { id: "ci", name: "CI pipeline", key_prefix: "sk-proxy-cd34", created_at: "2026-09-01T00:00:00Z", last_used_at: null },
  ];
  const revoked: string[] = [];
  await page.route("https://routing.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    const method = route.request().method();
    if (path === "/api/proxy-keys/cleanup") {
      expect(route.request().postDataJSON()).toEqual({ max_age_days: 7, dry_run: true });
      return route.fulfill({ json: { keys, cutoff: "2026-10-01T00:00:00Z", dry_run: true } });
    }
    if (method === "DELETE") {
      revoked.push(path);
      keys = keys.filter(key => !path.endsWith(`/${key.id}`));
      return route.fulfill({ status: 204 });
    }
    if (path === "/api/proxy-keys" && method === "POST") {
      const key = { id: "windsurf", name: route.request().postDataJSON().name, key_prefix: "sk-proxy-ef56", created_at: "2026-10-09T00:00:00Z", last_used_at: null };
      keys.push(key);
      return route.fulfill({ json: { ...key, key: "test-only-created-secret" } });
    }
    return route.fulfill({ json: path === "/api/proxy-keys" ? keys : [] });
  });
  await page.goto("/tests/routing-perf.html");
  // This lightweight fixture omits the title bar; keep main in the app's content row.
  await page.addStyleTag({ content: ".app > .main { grid-row: 2; }" });
  await page.evaluate(() => Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: async () => {} } }));
  await page.getByRole("button", { name: "Proxy API Keys", exact: true }).click();
  await expect(page.getByRole("button", { name: "Revoke Cursor", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "New Key", exact: true }).click();
  await page.getByLabel("Key name").fill("Windsurf");
  await page.getByRole("button", { name: "Create", exact: true }).click();
  await expect(page.getByText("test-only-created-secret")).toBeVisible();
  await page.getByRole("button", { name: "Copy key", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "Copied" })).toBeVisible();
  await page.getByRole("button", { name: "Done", exact: true }).click();
  await expect(page.getByText("test-only-created-secret")).toHaveCount(0);
  await page.getByRole("button", { name: "Clean Up", exact: true }).click();
  await page.getByRole("checkbox", { name: /Cursor/ }).uncheck();
  await page.getByRole("checkbox", { name: /Windsurf/ }).uncheck();
  await page.getByRole("button", { name: "Revoke 1 key", exact: true }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  expect(revoked).toEqual([]);
  await page.getByRole("dialog").getByRole("button", { name: "Revoke key", exact: true }).click();
  await expect(page.getByRole("button", { name: "Revoke CI pipeline", exact: true })).toHaveCount(0);
  expect(revoked).toEqual(["/api/proxy-keys/ci"]);

  await page.getByRole("button", { name: "Clean Up", exact: true }).click();
  await expect(page.getByRole("checkbox", { name: /Cursor/ })).toBeVisible();
  await page.locator(".settings-body").evaluate(el => { el.scrollTop = 0; });
  await expect(page.getByRole("heading", { name: "Routing", exact: true })).toBeInViewport();
  await page.waitForTimeout(150);
  await page.screenshot({ path: "/tmp/orb-proxy-keys-dark.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => {
    document.querySelector(".sidebar")?.remove();
    document.querySelector<HTMLElement>(".app")?.style.setProperty("--sb-w", "0px");
    document.documentElement.dataset.theme = "light";
  });
  await expect(page.getByRole("button", { name: "New Key", exact: true })).toBeVisible();
  await page.locator(".settings-body").evaluate(el => { el.scrollTop = 0; });
  await page.waitForTimeout(150);
  const bounds = await page.locator(".routing-page").evaluate(el => ({ width: el.clientWidth, scroll: el.scrollWidth }));
  expect(bounds.scroll).toBe(bounds.width);
  await page.screenshot({ path: "/tmp/orb-proxy-keys-light-narrow.png", fullPage: true });
});
