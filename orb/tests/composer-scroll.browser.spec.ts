import {eventPage} from "./eventPageFixture";
import { test, expect, type Page } from "@playwright/test";

const MISSION = "9f2a91c4-8b7d-4e21-9a0c-5d6e7f801235";
const answer = Array.from({length:10},(_,i)=>`${i+1}. **Question ${i+1}:** ${"Should we keep the current proof or change its scope before delivery? ".repeat(3)}`).join("\n");

async function setup(page: Page) {
  const mission = { id: MISSION, title: "Pareto audit", status: "awaiting_user", history: [], backend: "codex", created_at: "", updated_at: "" };
  const events = Array.from({length:6},(_,i)=>[
    { id:`u${i}`, event_id:`u${i}`, sequence:i*2+1, event_type:"user_message", content:`Request ${i}`, timestamp:"" },
    { id:`a${i}`, event_id:`a${i}`, sequence:i*2+2, event_type:"assistant_message", content:answer, timestamp:"" },
  ]).flat();
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
  await expect(page.locator(".st-text").last()).toContainText("Question 10");
}

test("typing a long reply keeps the transcript and the caret line where they are", async ({ page }) => {
  await setup(page);
  const scroll = page.locator(".scroll");
  // Reading the questions a little above the bottom, as when answering them.
  await scroll.evaluate(el => { el.scrollTop = el.scrollHeight - el.clientHeight - 200; el.dispatchEvent(new Event("scroll")); });
  const before = await scroll.evaluate(el => el.scrollTop);
  const input = page.locator(".composer textarea");
  await input.click();
  const hidden: string[] = [];
  const check = async (step: string) => {
    const [top, below] = await page.evaluate(() => {
      const t = document.querySelector(".composer textarea") as HTMLTextAreaElement;
      return [document.querySelector(".scroll")!.scrollTop, t.scrollHeight - t.scrollTop - t.clientHeight];
    });
    if (top !== before || below > 1) hidden.push(`${step}: transcript ${top}, ${below}px below caret`);
  };
  for (let i = 1; i <= 9; i++) {
    await input.pressSequentially(`${i}) answer ${i}`); await check(`${i}`);
    // A blank line between answers used to leave the new caret line out of view.
    await input.press("Shift+Enter"); await check(`${i}+`);
    await input.press("Shift+Enter"); await check(`${i}++`);
  }
  expect(await input.evaluate((el: HTMLTextAreaElement) => el.scrollHeight > el.clientHeight)).toBe(true);
  expect(hidden).toEqual([]);
});
