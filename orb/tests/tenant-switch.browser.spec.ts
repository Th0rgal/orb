import { test, expect } from "@playwright/test";

for (const nativeChrome of [false, true]) test(`switching users clears ${nativeChrome ? "native" : "HTML"} sidebar when new reads fail`, async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.addInitScript((nativeChrome) => {
    if (nativeChrome) {
      const w = window as any;
      w.__ORB_NATIVE_CHROME__ = true;
      w.__tenantSnapshots = [];
      w.__TAURI__ = { core: { invoke: async (command: string, args: unknown) => {
        if (command === "native_chrome_sync_state") w.__tenantSnapshots.push(args);
        return undefined;
      } } };
    }
    sessionStorage.setItem("tenant-test-boots", String(Number(sessionStorage.getItem("tenant-test-boots") || "0") + 1));
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "synthetic-admin");
  }, nativeChrome);
  const adminProject = { slug: "private-admin-project", title: "Private admin project" };
  const adminMission = { id: "private-admin-mission", title: "Private admin mission", project: adminProject.slug,
    status: "awaiting_user", backend: "codex", created_at: "2026-11-13T10:00:00Z", updated_at: "2026-11-13T10:00:00Z" };
  await page.route("**/api/**", route => {
    const path = new URL(route.request().url()).pathname;
    const member = route.request().headers().authorization === "Bearer synthetic-member";
    if (member && (path === "/api/projects" || path === "/api/control/missions")) {
      // A new account can be offline. Old-account data must already be gone.
      return route.fulfill({ status: 503, json: { error: "temporarily unavailable" } });
    }
    if (path === "/api/auth/me") return route.fulfill({ json: { auth_mode: "multi_user", user: {
      id: member ? "member" : "admin", username: member ? "member" : "admin", role: member ? "member" : "admin",
      daily_spend_cap_cents: 0, spent_today_cents: 0,
    } } });
    if (path === "/api/projects") return route.fulfill({ json: { projects: [adminProject] } });
    if (path === "/api/control/missions" || path === "/api/projects/private-admin-project/missions") return route.fulfill({ json: [adminMission] });
    if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
    const json = path === "/api/backends" || path === "/api/model-routing/chains" || path.endsWith("/queue") ? []
      : path === "/api/providers/backend-models" ? { backends: {} }
      : path === "/api/remote-nodes" ? { enabled: true, nodes: [] }
      : path.endsWith("/files") ? { entries: [] } : path.endsWith("/crons") ? { jobs: [] } : {};
    return route.fulfill({ json });
  });
  await page.goto("/");
  const sidebar = page.locator(".sb-scroll");
  const nativeSnapshot = () => page.evaluate(() => JSON.stringify((window as any).__tenantSnapshots.at(-1) || {}));
  if (nativeChrome) {
    await expect.poll(nativeSnapshot).toContain("Private admin project");
    await expect.poll(nativeSnapshot).toContain("Private admin mission");
  } else {
    await expect(sidebar).toContainText("Private admin project");
    await sidebar.getByRole("button", { name: "Private admin project", exact: true }).click();
    await expect(sidebar).toContainText("Private admin mission");
  }
  await page.evaluate(async () => {
    // Exercise the same connection change used by the desktop account UI.
    const api = await import("/src/api.ts");
    api.setConnection(location.origin, "synthetic-member");
  });
  if (nativeChrome) {
    await expect.poll(nativeSnapshot).not.toContain("Private admin project");
    await expect.poll(nativeSnapshot).not.toContain("Private admin mission");
    await expect(page.locator(".app[data-native-chrome='true']")).toBeVisible();
  } else {
    await expect(sidebar).not.toContainText("Private admin project");
    await expect(sidebar).not.toContainText("Private admin mission");
    await expect(sidebar.getByRole("button", { name: "New Agent", exact: false })).toBeVisible();
  }
  expect(await page.evaluate(() => sessionStorage.getItem("tenant-test-boots"))).toBe("1");
  expect(errors).toEqual([]);
});
