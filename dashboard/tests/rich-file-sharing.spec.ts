import { test, expect, APIRequestContext } from "@playwright/test";

const API_BASE = process.env.OPEN_AGENT_API_BASE || "http://127.0.0.1:3002";

async function waitForAssistantMessage(
  request: APIRequestContext,
  missionId: string,
  timeoutMs = 240_000
): Promise<{ content: string; shared_files?: unknown }> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const res = await request.get(`${API_BASE}/api/control/missions/${missionId}/events`);
    if (res.ok()) {
      const events = (await res.json()) as Array<{
        event_type?: string;
        content?: string;
        metadata?: unknown;
      }>;
      // Find the last assistant message event.
      for (let i = events.length - 1; i >= 0; i--) {
        const ev = events[i];
        if (ev?.event_type === "assistant_message") {
          const metadata = (ev as { metadata?: { shared_files?: unknown } }).metadata;
          return { content: String(ev.content ?? ""), shared_files: metadata?.shared_files };
        }
      }
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`Timed out waiting for assistant_message for mission ${missionId}`);
}

test.describe("Rich file sharing (inline <image>/<file> tags)", () => {
  test.setTimeout(300_000);

  test("renders inline image preview + file card, and backend emits shared_files metadata", async ({
    page,
    request,
  }) => {
    if (!process.env.RUN_RICH_FILE_SHARING_E2E) {
      test.skip(true, "Set RUN_RICH_FILE_SHARING_E2E=1 to run LLM-backed smoke test");
    }

    const workspacesRes = await request.get(`${API_BASE}/api/workspaces`);
    expect(workspacesRes.ok()).toBeTruthy();
    const workspaces = (await workspacesRes.json()) as Array<{
      id: string;
      workspace_type?: string;
    }>;
    const hostWorkspace =
      workspaces.find((ws) => ws.id === "00000000-0000-0000-0000-000000000000") ||
      workspaces.find((ws) => ws.workspace_type === "host");
    expect(hostWorkspace).toBeTruthy();

    const title = `pw-rich-tags-${Date.now()}`;
    const missionRes = await request.post(`${API_BASE}/api/control/missions`, {
      data: { title, workspace_id: hostWorkspace!.id, backend: "claudecode" },
      headers: { "Content-Type": "application/json" },
    });
    expect(missionRes.ok()).toBeTruthy();
    const mission = (await missionRes.json()) as { id: string };

    const loadRes = await request.post(`${API_BASE}/api/control/missions/${mission.id}/load`);
    expect(loadRes.ok()).toBeTruthy();

    const prompt = [
      "Create two files in the current working directory:",
      "- chart.svg: a simple SVG with a colored rectangle and the text 'OK'",
      "- report.txt: the text 'hello rich file sharing'",
      "",
      "Then reply with exactly these component tags on their own lines:",
      '<image path="./chart.svg" alt="Chart" />',
      '<file path="./report.txt" name="Report" />',
    ].join("\n");

    const messageRes = await request.post(`${API_BASE}/api/control/message`, {
      data: { content: prompt, mission_id: mission.id },
      headers: { "Content-Type": "application/json" },
    });
    expect(messageRes.ok()).toBeTruthy();

    const assistant = await waitForAssistantMessage(request, mission.id);
    expect(assistant.content).toContain('<image path="./chart.svg"');
    expect(assistant.content).toContain('<file path="./report.txt"');
    expect(assistant.shared_files).toBeTruthy();

    await page.addInitScript((base) => {
      localStorage.setItem("settings", JSON.stringify({ apiUrl: base }));
    }, API_BASE);

    await page.goto(`/control?mission=${mission.id}`);

    // InlineImagePreview renders an <img> with alt="Chart" once fetched.
    const img = page.locator('img[alt="Chart"]');
    await expect(img).toBeVisible({ timeout: 120_000 });

    // The card should have a download button (icon-only).
    const downloadButton = page.getByRole("button", { name: "Download" }).first();
    await expect(downloadButton).toBeVisible();

    // InlineFileCard renders a card with the display name near the download button.
    const fileCard = downloadButton.locator("..");
    await expect(fileCard).toContainText("Report");
  });
});
