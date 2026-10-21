import { expect, test, type Page } from "@playwright/test";
import { eventPage } from "./eventPageFixture";

const longTitle = "A very long mission title that keeps going and going so it would collide with the floating tools in the title bar if nothing truncated it";

async function openMission(page: Page, title: string, theme: string) {
  const events = Array.from({ length: 5 }, (_, i) => [
    { id: `u${i}`, event_id: `u${i}`, sequence: i * 2 + 1, event_type: "user_message", content: `Question number ${i + 1}`, timestamp: "" },
    { id: `a${i}`, event_id: `a${i}`, sequence: i * 2 + 2, event_type: "assistant_message", content: `Answer ${i + 1}\n\n${"Lorem ipsum dolor sit amet. ".repeat(30)}`, timestamp: "" },
  ]).flat();
  const mission = { id: "tools", title, status: "completed", project: "test", backend: "antigravity", github_pr: "Th0rgal/orb#1", history: [], created_at: "2026-10-09T10:00:00Z", updated_at: "2026-10-09T10:01:00Z" };
  await page.addInitScript(t => { localStorage.setItem("orb.apiUrl", location.origin); localStorage.setItem("orb.jwt", "test"); localStorage.setItem("orb-theme", t); }, theme);
  await page.route("**/api/**", route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/control/missions/tools" || path.endsWith("/opened")) return route.fulfill({ json: mission });
    if (path.endsWith("/events")) return route.fulfill(eventPage(route, events));
    if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
    const json = path === "/api/projects" ? { projects: [{ slug: "test", title: "test" }] }
      : path === "/api/control/missions" ? [mission]
      : path.endsWith("/manifest") ? { revision: 1, entries: {} }
      : path.endsWith("/files") ? { entries: [] } : [];
    return route.fulfill({ json });
  });
  await page.goto("/");
  const project = page.getByRole("button", { name: "test", exact: true });
  // A cold dev server can reload once while it optimises dependencies.
  if (!await project.waitFor({ timeout: 10_000 }).then(() => true, () => false)) await page.reload();
  await project.click();
  await page.getByRole("button", { name: title, exact: true }).click();
  await expect(page.getByPlaceholder("Send follow-up")).toBeVisible();
  await expect(page.locator(".mission-tools .chapters-btn")).toHaveCount(2);
}

const box = async (page: Page, sel: string) => (await page.locator(sel).first().boundingBox())!;
const overlaps = (a: { x: number; y: number; width: number; height: number }, b: typeof a) =>
  a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

for (const scheme of ["light", "dark"] as const) for (const width of [1100, 640]) {
  test(`mission tools sit centred in the title row (${scheme}, ${width}px)`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: scheme });
    await openMission(page, longTitle, scheme);
    await page.setViewportSize({ width, height: 800 });
    // Narrow windows open the sidebar as a modal drawer; close it to use the mission.
    const toggle = page.getByRole("button", { name: "Toggle sidebar" });
    if (width < 720 && await toggle.getAttribute("aria-expanded") === "true") await toggle.click();
    const bar = await box(page, ".titlebar"), tools = await box(page, ".mission-tools");
    const title = await box(page, ".session-title-text"), icon = await box(page, ".titlebar .files-toggle");
    // Vertically centred on the title row, like the title and the files icon.
    expect(Math.abs((tools.y + tools.height / 2) - (bar.y + bar.height / 2))).toBeLessThanOrEqual(3);
    expect(Math.abs((tools.y + tools.height / 2) - (icon.y + icon.height / 2))).toBeLessThanOrEqual(3);
    // Just left of the title-bar icons, never over them or the (truncated) title.
    expect(overlaps(tools, icon)).toBe(false);
    expect(tools.x + tools.width).toBeLessThanOrEqual(icon.x);
    expect(icon.x - (tools.x + tools.width)).toBeLessThanOrEqual(12);
    expect(overlaps(tools, title)).toBe(false);
    expect(await page.locator(".session-title-text").first().evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true);
    // The transcript starts below the title bar, so nothing hides under the pills.
    expect((await box(page, ".scroll")).y).toBeGreaterThanOrEqual(bar.y + bar.height - 1);
    if (process.env.ORB_SHOTS) await page.screenshot({ path: `${process.env.ORB_SHOTS}/tools-${scheme}-${width}.png` });
    // Both dropdowns open below their pill and above the transcript.
    for (const [i, list] of [[0, ".changes-list"], [1, ".chapters-list:not(.changes-list)"]] as const) {
      const pill = page.locator(".mission-tools .chapters-btn").nth(i);
      await pill.click();
      const menu = await box(page, list), p = (await pill.boundingBox())!;
      expect(menu.y).toBeGreaterThanOrEqual(p.y + p.height);
      expect(menu.x + menu.width).toBeLessThanOrEqual(width);
      const hit = await page.evaluate(([x, y]) => !!document.elementFromPoint(x, y)?.closest(".chapters-list"), [menu.x + menu.width / 2, menu.y + 10]);
      expect(hit).toBe(true);
      if (process.env.ORB_SHOTS && width === 1100) await page.screenshot({ path: `${process.env.ORB_SHOTS}/tools-${scheme}-${width}-menu${i}.png` });
      await page.keyboard.press("Escape");
    }
  });
}
