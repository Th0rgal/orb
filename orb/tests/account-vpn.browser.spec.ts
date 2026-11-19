import { expect, test } from "@playwright/test";

for (const theme of ["light", "dark"]) test(`account VPN retry and Direct selection in ${theme} mode`, async ({ page }) => {
  const changes: Array<[string, unknown]> = [];
  const accounts = ["a", "b"].map(id => ({
    id, name: "ChatGPT " + id, provider_type: "openai", account_email: id + "@example.invalid",
    uses_oauth: true, has_oauth: true, credential_owner: "cli_proxy", status: { type: "connected" },
  }));
  const direct = { mode: "direct", status: "direct", countries: ["NL", "US"], can_configure: true };
  await page.addInitScript(theme => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "fixture");
    localStorage.setItem("orb-theme", theme);
  }, theme);
  await page.route("**/api/**", route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/ai/providers") return route.fulfill({ json: accounts });
    if (path.endsWith("/vpn")) {
      if (route.request().method() === "GET") return route.fulfill({ json: direct });
      const body = route.request().postDataJSON();
      changes.push([path, body]);
      const vpn = { ...direct, mode: "vpn", country: "NL" };
      const result = body.mode === "direct" ? direct : changes.length === 1
        ? { ...vpn, status: "blocked", message: "All five AirVPN sessions are in use." }
        : { ...vpn, status: "verified", server: "west", exits: ["192.0.2.35"] };
      return route.fulfill({ json: result });
    }
    return route.fulfill({ json: path === "/api/projects" ? { projects: [] } : [] });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Inference", exact: true }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
  const group = page.locator(".p-group-head");
  await expect(group).toHaveCount(1);
  if (await group.getAttribute("aria-expanded") === "false") await group.click();
  await page.locator(".p-acc-btn").filter({ hasText: "b@example.invalid" }).click();
  const select = page.getByLabel("Account connection", { exact: true });
  await expect(select).toHaveValue("");
  await select.selectOption("NL");
  await expect(page.getByText("All five AirVPN sessions are in use.")).toBeVisible();
  await page.getByRole("button", { name: "Retry verification" }).click();
  const verified = page.getByText("Verified exit · west · 192.0.2.35");
  await expect(verified).toBeVisible();
  await select.selectOption("");
  await expect(verified).toHaveCount(0);
  const path = "/api/ai/providers/b/vpn";
  expect(changes).toEqual([[path, { mode: "vpn", country: "NL" }], [path, { mode: "vpn", country: "NL" }], [path, { mode: "direct" }]]);
});
