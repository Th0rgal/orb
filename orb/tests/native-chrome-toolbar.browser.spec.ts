import { test, expect, type Page } from "@playwright/test";

// Hybrid Native Chrome: the native shell draws the sidebar and its toolbar (toggle, search,
// back, forward) in a pane beside the WebView. The WebView must draw its own copy of that
// toolbar only while the native sidebar is closed. On Linux the WebView is often narrower than
// 720 px (window width minus the native pane), which used to collapse the WebView's idea of the
// sidebar while the native pane stayed open: two toolbars.

type SidebarCall = { open: boolean };

async function openHybridApp(page: Page) {
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    const w = window as unknown as { __ORB_NATIVE_CHROME__: boolean; __sidebarCalls: SidebarCall[] };
    w.__ORB_NATIVE_CHROME__ = true;
    w.__sidebarCalls = [];
    window.addEventListener("orb:set_native_sidebar", (event) => {
      w.__sidebarCalls.push((event as CustomEvent<SidebarCall>).detail);
    });
  });
  const missions = [{ id: "main", title: "Main conversation", status: "completed", project: "verity", tags: [] }];
  await page.route("**/api/**", (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname;
    if (path === "/api/control/missions/main") return route.fulfill({ json: missions[0] });
    const json =
      path === "/api/projects" ? { projects: [{ slug: "verity", title: "Verity" }] }
      : path === "/api/control/missions" ? missions
      : path.endsWith("/files") ? { entries: [] }
      : path.endsWith("/crons") ? { jobs: [] }
      : path.endsWith("/controller") ? { job: null, runs: [] }
      : [];
    return route.fulfill({ json });
  });
  await page.goto("/");
  await expect(page.locator(".app[data-native-chrome='true']")).toBeVisible();
}

const sidebarCalls = (page: Page) =>
  page.evaluate(() => (window as unknown as { __sidebarCalls: SidebarCall[] }).__sidebarCalls.map((c) => c.open));

const toggleNative = (page: Page, open: boolean) =>
  page.evaluate((next) => {
    (window as unknown as { __ORB_TOGGLE_NATIVE_SIDEBAR__: (open: boolean) => boolean }).__ORB_TOGGLE_NATIVE_SIDEBAR__(next);
  }, open);

for (const width of [700, 1100]) {
  test(`hybrid chrome draws one toolbar at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 800 });
    await openHybridApp(page);
    const app = page.locator(".app");
    const webToolbar = page.locator(".titlebar .tb-left");

    // Native sidebar open: the native pane owns the toolbar, whatever the WebView's width.
    await expect(app).toHaveAttribute("data-native-sb-open", "true");
    await expect(webToolbar).toBeHidden();
    expect((await sidebarCalls(page)).at(-1)).toBe(true);

    // Opening a page from the narrow WebView must not collapse the WebView's sidebar state.
    await page.evaluate(() => {
      (window as unknown as { __ORB_NATIVE_NAV__: (target: string) => boolean }).__ORB_NATIVE_NAV__("machines");
    });
    await expect(app).toHaveAttribute("data-native-sb-open", "true");
    await expect(webToolbar).toBeHidden();

    // The native toggle hides the native pane and tells the WebView, which takes the toolbar over.
    await toggleNative(page, false);
    await expect(app).toHaveAttribute("data-native-sb-open", "false");
    await expect(webToolbar).toBeVisible();
    await expect(webToolbar.getByRole("button", { name: "Toggle sidebar" })).toHaveCount(1);
    expect((await sidebarCalls(page)).at(-1)).toBe(false);

    // The WebView's toggle reopens the native pane and hands the toolbar back.
    await webToolbar.getByRole("button", { name: "Toggle sidebar" }).click();
    await expect(app).toHaveAttribute("data-native-sb-open", "true");
    await expect(webToolbar).toBeHidden();
    expect((await sidebarCalls(page)).at(-1)).toBe(true);
  });
}
