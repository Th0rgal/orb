import { expect, test } from "@playwright/test";

for (const theme of ["light", "dark"]) test(`account VPN retry and Direct selection in ${theme} mode`, async ({ page }) => {
  const changes: Array<[string, unknown]> = [];
  const accounts = ["a", "b"].map(id => ({
    id, name: "ChatGPT " + id, provider_type: "antigravity", account_email: id + "@example.invalid",
    added_by_me: id === "b", uses_oauth: true, has_oauth: true, credential_owner: "cli_proxy", status: { type: "connected" },
  }));
  let verifying = false;
  let routersAllowed = true;
  let refuseFirstChange = true;
  const routerWrites: string[] = [];
  const direct = { mode: "direct", status: "direct", countries: ["NL", "US"], can_configure: true };
  await page.addInitScript(theme => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "fixture");
    localStorage.setItem("orb-theme", theme);
  }, theme);
  await page.route("**/api/**", route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/auth/me") return route.fulfill({ json: { auth_mode: "multi_user",
      user: { id: "member", username: "member", role: "member" } } });
    if (path === "/api/ai/providers") return route.fulfill({ json: accounts });
    if (path.endsWith("/alternative-routers")) {
      if (route.request().method() === "PUT") {
        routerWrites.push(path);
        if (refuseFirstChange) {
          refuseFirstChange = false;
          return route.fulfill({ status: 503, json: { error: "sidecar_unavailable" } });
        }
        routersAllowed = route.request().postDataJSON().allowed;
      }
      return route.fulfill({ json: { allowed: routersAllowed } });
    }
    if (path.endsWith("/vpn")) {
      if (route.request().method() === "GET") {
        const verified = verifying && path === "/api/ai/providers/a/vpn";
        return route.fulfill({ json: verified ? { ...direct, mode: "vpn", country: "NL",
          status: "verified", server: "west", exits: ["192.0.2.35", "2001:db8:abcd:abcd:abcd:abcd:abcd:1234"] } : direct });
      }
      const body = route.request().postDataJSON();
      changes.push([path, body]);
      const vpn = { ...direct, mode: "vpn", country: "NL" };
      verifying = body.mode === "vpn" && changes.length === 2;
      const result = body.mode === "direct" ? direct : changes.length === 1
        ? { ...vpn, status: "blocked", message: "All five AirVPN sessions are in use." }
        : { ...vpn, status: "blocked", reason: "vpn_awaiting_verification", message: "Waiting for exit verification." };
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
  const shared = page.locator(".p-acc-btn").filter({ hasText: "a@example.invalid" });
  await shared.click();
  const routerToggle = page.getByRole("switch", { name: "Allow alternative routers" });
  await expect(routerToggle).toHaveCount(0);
  await expect(page.getByLabel("Account connection", { exact: true })).toBeVisible();
  await shared.click();
  await page.locator(".p-acc-btn").filter({ hasText: "b@example.invalid" }).click();
  await expect(routerToggle).toBeChecked();
  routersAllowed = false;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(routerToggle).not.toBeChecked();
  routersAllowed = true;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(routerToggle).toBeChecked();
  expect(routerWrites).toEqual([]);
  await routerToggle.click();
  await expect(page.getByRole("alert").filter({ hasText: "Could not confirm" })).toBeVisible();
  await expect(routerToggle).toBeChecked();
  await routerToggle.click();
  await expect(page.getByRole("alert").filter({ hasText: "Could not confirm" })).toBeVisible();
  await expect(routerToggle).toBeChecked();
  await routerToggle.click();
  await expect(routerToggle).not.toBeChecked();
  const own = page.locator(".p-acc-btn").filter({ hasText: "b@example.invalid" });
  await own.click();
  await own.click();
  await expect(routerToggle).not.toBeChecked();
  expect(routerWrites).toEqual(Array(2).fill("/api/ai/providers/b/alternative-routers"));
  await own.click();
  await shared.click();
  const select = page.getByLabel("Account connection", { exact: true });
  await expect(select).toHaveValue("");
  await select.selectOption("NL");
  await expect(page.getByText("All five AirVPN sessions are in use.")).toBeVisible();
  await page.getByRole("button", { name: "Retry verification" }).click();
  const verified = page.getByText("Verified exit · west · 192.0.2.35");
  await expect(page.getByText("Waiting for exit verification.")).toBeVisible();
  await expect(verified).toBeVisible({ timeout: 10000 });
  const countryBox = (await select.boundingBox())!;
  const statusBox = (await verified.boundingBox())!;
  expect(Math.max(statusBox.x - countryBox.x - countryBox.width,
    statusBox.y - countryBox.y - countryBox.height)).toBeGreaterThanOrEqual(8);
  await select.selectOption("");
  await expect(verified).toHaveCount(0);
  const path = "/api/ai/providers/a/vpn";
  // Another session changed the shared route while this account row stayed open.
  verifying = true;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(verified).toBeVisible();
  await expect(select).toHaveValue("NL");
  expect(changes).toEqual([[path, { mode: "vpn", country: "NL" }], [path, { mode: "vpn", country: "NL" }], [path, { mode: "direct" }]]);
});

test("admin imports an AirVPN profile and checks the saved key", async ({ page }) => {
  const key = "fixture-only-api-key";
  const profile = "[Interface]\nAddress = 10.1.2.3\nPrivateKey = fixture-only\n";
  const status = { api_key_configured: false, devices: [] as string[] };
  const writes: unknown[] = [];
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "fixture");
  });
  await page.route("**/api/**", route => {
    const path = new URL(route.request().url()).pathname;
    if (path !== "/api/settings/airvpn") return route.fulfill({ json: path === "/api/projects" ? { projects: [] } : [] });
    const method = route.request().method();
    if (method === "GET") return route.fulfill({ json: status });
    if (method === "POST") return route.fulfill({ json: { active_sessions: 1 } });
    const body = route.request().postDataJSON();
    writes.push(body);
    if (body.api_key) status.api_key_configured = true;
    if (body.device_id) status.devices.push(body.device_id);
    return route.fulfill({ json: { saved: true } });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.locator("summary").filter({ hasText: "Advanced" }).click();
  const keyField = page.getByLabel("AirVPN API key");
  await expect(keyField).toHaveAttribute("type", "password");
  await keyField.fill(key);
  await page.getByRole("button", { name: "Save key", exact: true }).click();
  await expect(keyField).toHaveValue("");
  await page.getByRole("button", { name: "Test saved key" }).click();
  await expect(page.getByRole("status").filter({ hasText: "AirVPN reports 1 active session." })).toBeVisible();
  await page.getByLabel("Device name", { exact: true }).fill("orb-a");
  await page.getByLabel("Server country code").fill("nl");
  await page.getByLabel("AirVPN server name").fill("West");
  const file = page.getByLabel("WireGuard profile", { exact: true });
  await file.setInputFiles({ name: "west.conf", mimeType: "text/plain", buffer: Buffer.from(profile) });
  await page.getByRole("button", { name: "Import profile" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Device profile saved." })).toBeVisible();
  await expect(file).toHaveValue("");
  expect(writes).toEqual([{ api_key: key }, { device_id: "orb-a", country: "NL", server: "West", profile }]);
  await expect(page.getByText(key, { exact: true })).toHaveCount(0);
  await expect(page.getByText("PrivateKey =", { exact: false })).toHaveCount(0);
});

test("older Core explains missing routing endpoints and retries after upgrade", async ({page}) => {
  let phase: "legacy" | "unavailable" | "ready" = "legacy";
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "fixture");
  });
  await page.route("**/api/**", route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/auth/me") return route.fulfill({json:{auth_mode:"multi_user",user:{id:"a",username:"admin",role:"admin"}}});
    if (path === "/api/ai/providers") return route.fulfill({json:[{id:"legacy",name:"Legacy account",provider_type:"antigravity",
      added_by_me:true, uses_oauth:true, has_oauth:true, credential_owner:"cli_proxy",status:{type:"connected"}}]});
    if (path.startsWith("/api/ai/providers/legacy/") && /\/(vpn|alternative-routers)$/.test(path)) {
      expect(route.request().method()).toBe("GET");
      if (phase === "unavailable") return route.fulfill(path.endsWith("/vpn")
        ? {status:404,json:{error:"provider_not_found"}} : {status:503,json:{error:"sidecar_unavailable"}});
      if (phase === "legacy") return route.fulfill({status:404,json:{error:"not_found",path}});
      return route.fulfill({json:path.endsWith("/vpn") ? {mode:"direct",status:"direct",countries:["NL"],can_configure:true} : {allowed:false}});
    }
    return route.fulfill({json:path === "/api/projects" ? {projects:[]} : []});
  });
  await page.goto("/");
  await page.getByRole("button",{name:"Inference",exact:true}).click();
  const group = page.locator(".p-group-head");
  if (await group.count() && await group.getAttribute("aria-expanded") === "false") await group.click();
  await page.locator(".p-acc-btn").first().click();
  await expect(page.getByText("Update Core to configure account VPNs.")).toBeVisible();
  await expect(page.getByText("Update Core to configure alternative router access.")).toBeVisible();
  await expect(page.getByLabel("Account connection",{exact:true})).toHaveCount(0);
  await expect(page.getByRole("switch",{name:"Allow alternative routers"})).toHaveCount(0);
  phase = "unavailable";
  await page.getByRole("button",{name:"Retry connection settings"}).click();
  await page.getByRole("button",{name:"Retry router settings"}).click();
  await expect(page.getByText(/Update Core to configure/)).toHaveCount(0);
  await expect(page.getByLabel("Account connection",{exact:true})).toHaveCount(0);
  await expect(page.getByRole("switch",{name:"Allow alternative routers"})).toHaveCount(0);
  phase = "ready";
  await page.getByRole("button",{name:"Retry connection settings"}).click();
  await page.getByRole("button",{name:"Retry router settings"}).click();
  await expect(page.getByLabel("Account connection",{exact:true})).toHaveValue("");
  await expect(page.getByRole("switch",{name:"Allow alternative routers"})).toBeVisible();
  await expect(page.getByRole("switch",{name:"Allow alternative routers"})).not.toBeChecked();
  await expect(page.getByText(/Update Core to configure/)).toHaveCount(0);
});
