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
