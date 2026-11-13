import type { Page } from "@playwright/test";
import { eventPage } from "./eventPageFixture";

export const sideMissionId = "e8cdf55f-a668-4802-81c2-8ccc33fd15b0";

type FixtureEvent = Record<string, unknown>;

/** Full app with one project and one open conversation, API served from memory. */
export async function openConversation(page: Page, theme: "dark" | "light", events: FixtureEvent[], status = "completed") {
  await page.addInitScript((mode) => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", mode);
  }, theme);
  const mission = {
    id: sideMissionId, title: "Ledger hub build", status, project: "ethereum", backend: "claude_code",
    history: [], created_at: "2026-11-07T06:00:00Z", updated_at: "2026-11-07T06:10:00Z",
  };
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname;
    if (/^\/api\/control\/missions\/[^/]+$/.test(path)) return route.fulfill({ json: mission });
    if (path.endsWith("/opened")) return route.fulfill({ json: mission });
    if (path === `/api/control/missions/${sideMissionId}/events`) return route.fulfill(eventPage(route, events));
    if (path.endsWith("/events")) return route.fulfill(eventPage(route, []));
    if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
    if (path === "/api/projects") return route.fulfill({ json: { projects: [{ slug: "ethereum", title: "Ethereum" }] } });
    if (path === "/api/control/missions") return route.fulfill({ json: url.searchParams.has("tag") ? [] : [mission] });
    if (path.endsWith("/manifest")) return route.fulfill({ json: { revision: 1, entries: {} } });
    if (path.endsWith("/files")) return route.fulfill({ json: { entries: [] } });
    if (path.endsWith("/crons")) return route.fulfill({ json: { jobs: [] } });
    if (path.endsWith("/controller")) return route.fulfill({ json: { job: null, runs: [] } });
    return route.fulfill({ json: [] });
  });
  await page.goto("/");
  // A narrow window starts with the sidebar closed.
  const project = page.getByRole("button", { name: "Ethereum", exact: true });
  if ((page.viewportSize()?.width ?? 1100) <= 720) await page.getByRole("button", { name: "Toggle sidebar" }).first().click();
  await project.click();
  await page.getByRole("button", { name: "Ledger hub build", exact: true }).click();
}

export const longConversation: FixtureEvent[] = Array.from({ length: 10 }, (_, i) => [
  { id: `u-${i}`, event_id: `u-${i}`, sequence: i * 2 + 1, event_type: "user_message", content: `Turn ${i + 1}: check stage ${i + 1}`, timestamp: "2026-11-07T06:00:00Z" },
  { id: `a-${i}`, event_id: `a-${i}`, sequence: i * 2 + 2, event_type: "assistant_message", content: `Verified stage ${i + 1}.\n\n${"Transcript text that must never show through the side panel. ".repeat(14)}`, timestamp: "2026-11-07T06:01:00Z" },
]).flat();
