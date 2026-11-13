import { expect, test } from "@playwright/test";

for (const recoverImmediately of [true, false]) {
  test(`a malformed mission read ${recoverImmediately ? "recovers before sending" : "keeps the draft for retry"}`, async ({ page }) => {
    let invalidReads = 0;
    let reads = 0;
    const messages: Record<string, unknown>[] = [];
    const mission = { id: "read-recovery", backend: "antigravity", status: "completed", project: "default", track: "mission-read-recovery", history: [], created_at: "", updated_at: "" };
    await page.route("**/api/**", async route => {
      const path = new URL(route.request().url()).pathname;
      if (path === "/api/control/missions/read-recovery") {
        reads++;
        if (invalidReads-- > 0) return route.fulfill({ status: 200, contentType: "application/json", body: '{"id":' });
        return route.fulfill({ json: mission });
      }
      if (path === "/api/control/message") {
        const message = route.request().postDataJSON();
        messages.push(message);
        return route.fulfill({ json: { id: message.client_message_id, queued: false, message_accepted: true } });
      }
      if (path.endsWith("/events")) return route.fulfill({ json: [], headers: { "X-Orb-Events-Protocol": "1", "X-Has-More": "false", "X-Max-Sequence": "0" } });
      if (path === "/api/projects") return route.fulfill({ json: { projects: [{ slug: "default", title: "Default" }] } });
      return route.fulfill({ json: [] });
    });
    await page.goto("/tests/message-recovery.html");
    const input = page.getByRole("textbox");
    await expect(input).toBeVisible();
    await expect.poll(() => reads).toBeGreaterThan(0);
    invalidReads = recoverImmediately ? 1 : 2;
    const text = "Keep this exact follow-up through a failed mission read.";
    await input.fill(text);
    await input.press("Enter");
    if (!recoverImmediately) {
      await expect(page.getByText(/Couldn’t read the server response/)).toBeVisible();
      expect(messages).toHaveLength(0);
      await expect(page.locator(".user")).toContainText(text);
      await page.getByRole("button", { name: "Retry", exact: true }).click();
    }
    await expect.poll(() => messages.length).toBe(1);
    expect(messages[0]).toMatchObject({ content: text, mission_id: "read-recovery", continue_identity: { project: "default", track: "mission-read-recovery", github_pr: null } });
    await expect(page.getByText("Couldn’t send your message", { exact: true })).toHaveCount(0);
    await expect(page.locator(".user")).toHaveCount(1);
    await expect(page.locator(".user")).toContainText(text);
  });
}

test("734c3bb7 sequence clears Starting row and launch/status banner and labels listed queue row Not delivered", async ({ page }) => {
  let snapshot: Record<string, unknown> = {
    id: "read-recovery",
    backend: "opencode",
    status: "starting",
    run_generation: 3,
    state_revision: 5,
    project: "default",
    track: "mission-read-recovery",
    history: [],
    created_at: "2026-11-13T11:00:00Z",
    updated_at: "2026-11-13T11:48:00Z",
  };
  let events: Record<string, unknown>[] = [
    { id: 1, event_id: "u1", sequence: 1, event_type: "user_message", timestamp: "2026-11-13T11:00:00Z", content: "Initial prompt", metadata: { queued: false } },
  ];
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/control/missions/read-recovery") return route.fulfill({ json: snapshot });
    if (path === "/api/control/queue") {
      return route.fulfill({ json: [{ id: "steer-1", mission_id: "read-recovery", content: "Please stop and summarize", source: "remote-queue" }] });
    }
    if (path.endsWith("/events")) {
      const url = new URL(route.request().url());
      const since = Number(url.searchParams.get("since_seq") ?? "0");
      const pageRows = events.filter(e => Number(e.sequence) > since);
      const max = String(events.length);
      return route.fulfill({ json: pageRows, headers: { "X-Orb-Events-Protocol": "1", "X-Has-More": "false", "X-Max-Sequence": max, "X-Next-Cursor": max, "X-Page-Max-Sequence": max } });
    }
    if (path === "/api/projects") return route.fulfill({ json: { projects: [{ slug: "default", title: "Default" }] } });
    return route.fulfill({ json: [] });
  });
  await page.goto("/tests/message-recovery.html");
  // While the mission is starting, the transcript shows the Starting working row;
  // a moving phase renders no launch banner (it is only shown when settled).
  await expect(page.locator(".st-working")).toContainText("Starting OpenCode");
  await expect(page.locator(".launch-status")).toHaveCount(0);
  await expect(page.locator(".followup-queue .queue-count")).toHaveText("1 Queued");

  // Feed 734c3bb7 completion from another session (Core-emitted fields only)
  snapshot = {
    id: "read-recovery",
    backend: "opencode",
    status: "completed",
    terminal_reason: "completed",
    run_generation: 3,
    state_revision: 9,
    project: "default",
    track: "mission-read-recovery",
    history: [],
    created_at: "2026-11-13T11:00:00Z",
    updated_at: "2026-11-13T12:10:00Z",
  };
  events = [
    ...events,
    { id: 2, event_id: "a1", sequence: 2, event_type: "assistant_message", timestamp: "2026-11-13T12:10:00Z", content: "Completed summary.", metadata: { success: true } },
  ];
  await page.evaluate(() => window.dispatchEvent(new Event("orb:refresh")));
  await expect(page.locator(".st-working")).toHaveCount(0);
  await expect(page.locator(".launch-status")).toHaveCount(0);
  await expect(page.locator(".followup-queue .queue-count")).toHaveText("1 Not delivered");
  await expect(page.locator(".followup-queue")).toContainText("Not delivered · mission ended before delivery");

  // Feed a stale active snapshot from lower state_revision (3, 7) with a newer updated_at
  snapshot = {
    id: "read-recovery",
    backend: "opencode",
    status: "active",
    run_generation: 3,
    state_revision: 7,
    project: "default",
    track: "mission-read-recovery",
    history: [],
    created_at: "2026-11-13T11:00:00Z",
    updated_at: "2026-11-13T12:19:30Z",
  };
  await page.evaluate(() => window.dispatchEvent(new Event("orb:refresh")));
  await expect(page.locator(".st-working")).toHaveCount(0);
  await expect(page.locator(".launch-status")).toHaveCount(0);
  await expect(page.locator(".followup-queue .queue-count")).toHaveText("1 Not delivered");
});
