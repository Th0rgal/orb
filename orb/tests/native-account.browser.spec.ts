import { expect, test } from "@playwright/test";

test("expired native handoff signs in by keyboard and disconnects the displayed credential", async ({ page }) => {
  await page.addInitScript(() => {
    const events: Array<{command: string; args: unknown}> = [];
    let readOnly = true;
    Object.assign(window, {
      accountEvents: events,
      __TAURI__: { core: { invoke: async (command: string, args: unknown) => {
        events.push({ command, args });
        if (command === "desktop_connection_save" && (args as {connection: unknown}).connection === null && readOnly) {
          readOnly = false;
          throw new Error("Read-only fixture");
        }
        if (command === "desktop_bootstrap") {
          return { connection: { api_url: location.origin, token: "expired" } };
        }
        return null;
      } } },
    });
  });
  let signedIn = false;
  await page.route("**/api/**", async route => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    if (path === "/api/auth/login") {
      expect(request.method()).toBe("POST");
      expect(request.postDataJSON()).toEqual({ username: "Ben", password: "fixture-password" });
      signedIn = true;
      return route.fulfill({ json: { token: "replacement" } });
    }
    if (path === "/api/health") return route.fulfill({ json: { auth_required: true, auth_mode: "multi_user" } });
    if (path === "/api/auth/me" || path === "/api/auth/status") {
      if (!signedIn) return route.fulfill({ status: 401 });
      return route.fulfill({ json: { authenticated: true, auth_mode: "multi_user", user: { id: "ben", username: "Ben", role: "member" } } });
    }
    return route.fulfill({ status: 404 });
  });
  await page.goto("/#account-settings");
  await page.getByRole("textbox", { name: "Username" }).fill("Ben");
  const password = page.getByLabel("Password", { exact: true });
  await expect(password).toHaveAttribute("type", "password");
  await password.fill("fixture-password");
  await password.press("Enter");
  await expect(page.getByText("@Ben · Member")).toBeVisible();
  const disconnect = page.getByRole("button", { name: "Disconnect", exact: true });
  await disconnect.click();
  await expect(page.getByText("Could not disconnect the saved account.", { exact: false }).first()).toBeVisible();
  await expect(page.getByText("@Ben · Member")).toBeVisible();
  await disconnect.click();
  await expect(page.getByRole("textbox", { name: "Username" })).toBeVisible();
  const calls = await page.evaluate(() => (window as unknown as {
    accountEvents: Array<{command: string; args: unknown}>
  }).accountEvents);
  const endpoint = new URL(page.url()).origin;
  expect(calls.filter(c => c.command === "desktop_connection_save").map(c => c.args)).toEqual([
    { connection: { api_url: endpoint, token: "replacement" } },
    { connection: null, expected: { api_url: endpoint, token: "replacement" } },
    { connection: null, expected: { api_url: endpoint, token: "replacement" } },
  ]);
  expect(calls.map(c => c.command)).not.toContain("local_origin_disconnect");
  expect(calls.map(c => c.command)).not.toContain("ui_cache_clear");
  expect(JSON.stringify(calls)).not.toContain("fixture-password");
});

for (const usernameValue of ["Ben", ""]) {
  test(`unavailable health permits ${usernameValue ? "named-account" : "password-only"} login`, async ({ page }) => {
    await page.addInitScript(() => {
      localStorage.setItem("orb.apiUrl", location.origin);
      Object.assign(window, { __TAURI__: { core: { invoke: async () => null } } });
    });
    let login: unknown;
    await page.route("**/api/**", async route => {
      const path = new URL(route.request().url()).pathname;
      if (path === "/api/health") return route.fulfill({ status: 503, body: "{}" });
      if (path === "/api/auth/login") {
        login = route.request().postDataJSON();
        return route.fulfill({ json: { token: "fixture-session" } });
      }
      if (path === "/api/auth/me" && login) {
        return route.fulfill({ json: { auth_mode: "multi_user", user: { id: "ben", username: "Ben", role: "member" } } });
      }
      return route.fulfill({ status: 401, body: "{}" });
    });
    const healthFailure = page.waitForResponse(r => new URL(r.url()).pathname === "/api/health" && r.status() === 503);
    await page.goto("/#account-settings");
    await healthFailure;
    const username = page.getByRole("textbox", { name: "Username" });
    await expect(username).toBeVisible();
    if (usernameValue) await username.fill(usernameValue);
    await page.getByLabel("Password", { exact: true }).fill("fixture-password");
    await page.getByRole("button", { name: "Connect", exact: true }).click();
    const credentials = usernameValue ? { username: usernameValue, password: "fixture-password" } : { password: "fixture-password" };
    await expect.poll(() => login).toEqual(credentials);
  });
}
