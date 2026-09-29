import {eventPage} from "./eventPageFixture";
import { test, expect, type Page } from "@playwright/test";

const MISSION = "9f2a91c4-8b7d-4e21-9a0c-5d6e7f801236";
const answer = Array.from({length:10},(_,i)=>`${i+1}. **Question ${i+1}:** ${"Should we keep the current proof or change its scope before delivery? ".repeat(3)}`).join("\n");

async function setup(page: Page) {
  const mission = { id: MISSION, title: "Pareto audit", status: "awaiting_user", history: [], backend: "codex", created_at: "", updated_at: "" };
  const wake = "Background task `bjikajbtt` (`until timeout 20 ssh th0rgal@100.77.4.93 'test -f ~/work/pareto/exit.json'; do sleep 60; done; tail -3 build.log`) finished. Output:\n\n```\n\n\n[killed]\n```\n\nContinue from here.";
  const events = [
    { id:"u1", event_id:"u1", sequence:1, event_type:"user_message", content:"please review and merge the prs", timestamp:"" },
    { id:"a1", event_id:"a1", sequence:2, event_type:"assistant_message", content:"J'attends encore la revue de #2459.", timestamp:"" },
    { id:"u2", event_id:"u2", sequence:3, event_type:"user_message", content:wake, timestamp:"" },
    { id:"a2", event_id:"a2", sequence:4, event_type:"assistant_message", content:"Build finished.", timestamp:"" },
    { id:"u3", event_id:"u3", sequence:5, event_type:"user_message", content:"Background task `b2` (`make`) finished. Output:\n\n```\nall green\n```\n\nContinue from here.", metadata:{source:"background-task"}, timestamp:"" },
  ];
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", "dark");
  });
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/model-routing/chains") return route.fulfill({json:[]});
    if (path.endsWith("/events")) return route.fulfill(eventPage(route, events));
    if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
    if (path.endsWith("/queue")) return route.fulfill({ json: [] });
    if (path.startsWith("/api/control/missions/")) return route.fulfill({ json: mission });
    const json = path === "/api/projects" ? { projects: [{ slug: "test", title: "Test" }] }
      : path === "/api/control/missions" ? [mission]
      : path === "/api/backends" ? [{ id: "codex", name: "Codex" }]
      : path === "/api/providers/backend-models" ? { backends: { codex: [{ value: "gpt-6-astra", label: "GPT-6 Astra" }] } }
      : path === "/api/remote-nodes" ? { enabled: true, nodes: [] }
      : path.endsWith("/files") ? { entries: [] }
      : path.endsWith("/crons") ? { jobs: [] } : { job: null, runs: [] };
    await route.fulfill({ json });
  });
  await page.goto(`/#`);
  await page.getByRole("button", { name: "Test", exact: true }).click();
  await page.getByRole("button", { name: /Pareto audit/ }).click();
  await expect(page.locator(".st-text").last()).toContainText("Build finished.");
}

test("background-task wakes read as automatic status lines, not the user's messages", async ({ page }) => {
  await setup(page);
  await expect(page.locator(".user")).toHaveCount(1);
  await expect(page.locator(".user")).toContainText("please review and merge the prs");
  const wakes = page.locator(".background-wake");
  await expect(wakes).toHaveCount(2);
  await expect(wakes.first().locator("summary")).toContainText("Background task was stopped · agent resumed");
  await expect(wakes.nth(1).locator("summary")).toContainText("Background task finished · agent resumed");
  await expect(page.getByText("Continue from here.")).toHaveCount(0);
  await wakes.nth(1).locator("summary").click();
  await expect(wakes.nth(1).locator("pre").last()).toHaveText("all green");
  await wakes.first().locator("summary").click();
  await expect(wakes.first()).toContainText("killed before it finished");
  await page.screenshot({ path: "/tmp/background-wake.png" });
});
