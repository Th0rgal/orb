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

// The native sidebar has no HTML rows, so its "+" buttons (Projects section, project and folder
// rows) reach the WebView only through `__ORB_NATIVE_NAV__`. Without these targets the native
// sidebar had no way to start a project, or an agent inside a project or folder.
test("native sidebar + buttons open New project and New agent in a project or folder", async ({ page }) => {
  await openHybridApp(page);
  const nav = (target: string) =>
    page.evaluate((t) => (window as unknown as { __ORB_NATIVE_NAV__: (target: string) => boolean }).__ORB_NATIVE_NAV__(t), target);

  expect(await nav("new-project")).toBe(true);
  const dialog = page.getByRole("dialog").filter({ hasText: "Create project" });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByPlaceholder("Project name")).toBeFocused();
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await expect(dialog).toBeHidden();

  expect(await nav("new-agent:verity:docs/specs")).toBe(true);
  const composer = page.locator(".composer").first();
  await expect(composer).toBeVisible();
  const folder = page.locator(".new-agent-folder");
  await expect(folder).toHaveText("/ docs/specs");
  // The target is an action, never a page id: the app stays on the New Agent page.
  await expect(page.locator(".titlebar")).toContainText("New Agent");

  expect(await nav("new-agent:verity")).toBe(true);
  await expect(folder).toHaveCount(0);
  await expect(composer).toBeVisible();
});

test("native project menu confirms deletion before retiring the project", async ({ page }) => {
  await openHybridApp(page);
  const writes: unknown[] = [];
  await page.route("**/api/projects/verity/action", route => {
    writes.push(route.request().postDataJSON());
    return route.fulfill({ json: { ok: true } });
  });
  await expect(async () => {
    await page.evaluate(() => window.dispatchEvent(new CustomEvent("orb:native-project-menu", {
      detail: { slug: "verity", y: 80 },
    })));
    await expect(page.getByRole("menuitem", { name: "Delete project…" })).toBeVisible({ timeout: 500 });
  }).toPass();
  await page.getByRole("menuitem", { name: "Delete project…" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Delete Verity?");
  expect(writes).toEqual([]);
  await dialog.getByRole("button", { name: "Delete project" }).click();
  await expect(dialog).toHaveCount(0);
  expect(writes).toEqual([{ action: "delete" }]);
});

test("native project action bridge executes all project actions in hybrid mode", async ({ page }) => {
  await openHybridApp(page);
  const actions: unknown[] = [];
  await page.route("**/api/projects/verity/action", (route) => {
    actions.push(route.request().postDataJSON());
    return route.fulfill({ json: { ok: true } });
  });
  await page.route("**/api/projects", (route) => {
    if (route.request().method() === "PUT") {
      actions.push(route.request().postDataJSON());
      return route.fulfill({ json: { slug: "verity", title: "Verity Renamed" } });
    }
    return route.fallback();
  });

  const invokeProjectAction = (action: string, slug: string) =>
    page.evaluate(
      ([a, s]) =>
        (window as unknown as { __ORB_NATIVE_PROJECT_ACTION__: (action: string, slug: string) => boolean }).__ORB_NATIVE_PROJECT_ACTION__(a, s),
      [action, slug],
    );

  // new-agent
  expect(await invokeProjectAction("new-agent", "verity")).toBe(true);
  await expect(page.locator(".composer").first()).toBeVisible();
  await expect(page.locator(".titlebar")).toContainText("New Agent");

  // new-cloud-agent
  expect(await invokeProjectAction("new-cloud-agent", "verity")).toBe(true);
  await expect(page.locator(".titlebar")).toContainText(/Cloud [Aa]gent/);

  // settings
  expect(await invokeProjectAction("settings", "verity")).toBe(true);
  await expect(page.locator(".titlebar")).toContainText("Settings");

  // new-folder opens NameDialog
  expect(await invokeProjectAction("new-folder", "verity")).toBe(true);
  const folderDialog = page.getByRole("dialog").filter({ hasText: "New folder" });
  await expect(folderDialog).toBeVisible();
  await folderDialog.getByRole("button", { name: "Cancel" }).click();
  await expect(folderDialog).toHaveCount(0);

  // rename opens NameDialog and saves
  expect(await invokeProjectAction("rename", "verity")).toBe(true);
  const renameDialog = page.getByRole("dialog").filter({ hasText: "Rename" });
  await expect(renameDialog).toBeVisible();
  await renameDialog.getByRole("textbox").fill("Verity Renamed");
  await renameDialog.getByRole("button", { name: "Rename" }).click();
  await expect(renameDialog).toHaveCount(0);
  await expect.poll(() => actions).toContainEqual({ slug: "verity", title: "Verity Renamed" });

  // delete opens ConfirmDialog and confirms
  expect(await invokeProjectAction("delete", "verity")).toBe(true);
  const deleteDialog = page.getByRole("dialog").filter({ hasText: "Delete Verity" });
  await expect(deleteDialog).toBeVisible();
  await deleteDialog.getByRole("button", { name: "Delete project" }).click();
  await expect(deleteDialog).toHaveCount(0);
  expect(actions).toContainEqual({ action: "delete" });

  // archive calls retire endpoint directly
  expect(await invokeProjectAction("archive", "verity")).toBe(true);
  await expect.poll(() => actions).toContainEqual({ action: "archive" });
});
