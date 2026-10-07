import { expect, test } from "@playwright/test";

test("Inbox surfaces Needs You and Ready for Review while keeping working agents quiet, with keyboard triage and inline reply", async ({
  page,
}) => {
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test-token");
    localStorage.setItem("orb-theme", "dark");
  });

  const statusUpdates: Array<{ id: string; status: string }> = [];
  const sentMessages: Array<{ id: string; content: string }> = [];
  const toolResults: Array<Record<string, unknown>> = [];

  const missions = [
    {
      id: "m-working",
      title: "Compile Lean proof on Spark",
      status: "running",
      project: "paloma",
      backend: "claudecode",
      remote_node_id: "dgx-spark",
      history: [],
      created_at: "2026-10-07T11:50:00Z",
      updated_at: "2026-10-07T11:58:00Z",
    },
    {
      id: "m-perm",
      title: "Migrate mission schema",
      status: "running",
      project: "orb",
      backend: "claudecode",
      history: [],
      created_at: "2026-10-07T11:40:00Z",
      updated_at: "2026-10-07T11:56:00Z",
    },
    {
      id: "m-question",
      title: "Design iOS Inbox gesture",
      status: "awaiting_user",
      project: "orb",
      backend: "codex",
      history: [
        { role: "user", content: "Propose the swipe gesture for Orb iOS Inbox." },
        {
          role: "assistant",
          content:
            "Should swipe-right mark the conversation as Done immediately with an Undo toast, or open a confirmation sheet?",
        },
      ],
      created_at: "2026-10-07T11:20:00Z",
      updated_at: "2026-10-07T11:52:00Z",
    },
    {
      id: "m-failed",
      title: "CTRL-G Docker/Lean inspection",
      status: "failed",
      project: "paloma",
      backend: "claudecode",
      terminal_reason: "Docker daemon unreachable in host workspace.",
      created_at: "2026-10-07T11:10:00Z",
      updated_at: "2026-10-07T11:51:00Z",
    },
    {
      id: "m-done",
      title: "Fix sidebar scroll thumb",
      status: "completed",
      project: "paloma",
      backend: "claudecode",
      history: [
        { role: "user", content: "Hide the sidebar scroll thumb until hover." },
        {
          role: "assistant",
          content:
            "Updated the scroll thumb track to remain hidden until pointer hover and verified all Playwright checks pass.",
        },
      ],
      created_at: "2026-10-07T10:00:00Z",
      updated_at: "2026-10-07T11:30:00Z",
    },
    {
      id: "m-child-fail",
      title: "Track G-4 Proof Closure",
      status: "failed",
      project: "paloma",
      parent_mission_id: "m-done",
      created_at: "2026-10-07T11:25:00Z",
      updated_at: "2026-10-07T11:32:00Z",
    },
  ];

  await page.route("**/api/**", async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    const path = url.pathname;

    if (path === "/api/projects") {
      await route.fulfill({
        json: {
          projects: [
            { slug: "orb", title: "Orb", color: "blue" },
            { slug: "paloma", title: "Paloma", color: "amber" },
          ],
        },
      });
      return;
    }

    if (path === "/api/control/missions" && req.method() === "GET") {
      const proj = url.searchParams.get("project");
      const list = proj ? missions.filter((m) => m.project === proj) : missions;
      await route.fulfill({ json: list });
      return;
    }

    if (path === "/api/control/missions/m-perm/events") {
      await route.fulfill({
        headers: {
          "X-Orb-Events-Protocol": "1",
          "X-Has-More": "false",
          "X-Next-Cursor": "1",
          "X-Page-Max-Sequence": "1",
          "X-Max-Sequence": "1",
        },
        json: [
          {
            id: 1,
            sequence: 1,
            event_type: "tool_call",
            timestamp: "2026-10-07T11:56:00Z",
            tool_call_id: "call-perm-99",
            tool_name: "ui_native_request",
            content: JSON.stringify({
              method: "permission",
              params: {
                tool: "Bash",
                input: {
                  command: "sqlx migrate run",
                  description: "Apply the pending SQLite migration.",
                },
              },
            }),
          },
        ],
      });
      return;
    }

    if (path.endsWith("/events")) {
      await route.fulfill({
        headers: {
          "X-Orb-Events-Protocol": "1",
          "X-Has-More": "false",
        },
        json: [],
      });
      return;
    }

    if (path.endsWith("/queue") && req.method() === "GET") {
      await route.fulfill({ json: [] });
      return;
    }

    if (path === "/api/control/tool_result" && req.method() === "POST") {
      const body = req.postDataJSON() as Record<string, unknown>;
      toolResults.push(body);
      await route.fulfill({ json: { delivered: true } });
      return;
    }

    const getMissionMatch = path.match(/^\/api\/control\/missions\/([^/]+)$/);
    if (getMissionMatch && req.method() === "GET") {
      const id = decodeURIComponent(getMissionMatch[1]);
      const found = missions.find((m) => m.id === id);
      await route.fulfill({ json: found ?? { id, status: "completed", history: [] } });
      return;
    }

    const statusMatch = path.match(/^\/api\/control\/missions\/([^/]+)\/status$/);
    if (statusMatch && req.method() === "POST") {
      const id = decodeURIComponent(statusMatch[1]);
      const body = req.postDataJSON() as { status: string };
      statusUpdates.push({ id, status: body.status });
      const target = missions.find((m) => m.id === id);
      if (target) target.status = body.status;
      await route.fulfill({ json: { ok: true } });
      return;
    }

    if (path === "/api/control/message" && req.method() === "POST") {
      const body = req.postDataJSON() as { mission_id: string; content: string };
      sentMessages.push({ id: body.mission_id, content: body.content });
      const target = missions.find((m) => m.id === body.mission_id);
      if (target) target.status = "running";
      await route.fulfill({ json: { id: "msg-1", queued: false } });
      return;
    }

    await route.fulfill({ json: {} });
  });

  await page.goto("/");

  // Sidebar shows Inbox with actionable badge count (4: m-perm, m-question, m-failed, m-done; m-working & m-child-fail are quiet/grouped)
  const inboxNav = page.locator("#orb-sidebar").getByRole("button", { name: /Inbox/ });
  await expect(inboxNav).toBeVisible();
  await expect(inboxNav.locator(".inbox-sb-badge")).toHaveText("4");

  // Open Inbox via ⌘I shortcut
  await page.keyboard.press("Meta+KeyI");
  await expect(page.locator(".inbox-page h2")).toHaveText("Inbox");

  // Unread filter is selected by default
  const unreadTab = page.locator('[data-inbox-filter="unread"]');
  await expect(unreadTab).toHaveClass(/on/);
  await expect(unreadTab).toContainText("Unread");

  // Working agent is quiet behind the "1 working" pill, not in the main list
  const workingPill = page.locator(".inbox-working-pill");
  await expect(workingPill).toContainText("1 working");
  await expect(page.locator(".inbox-page")).not.toContainText("Compile Lean proof on Spark");

  // Clicking the working pill reveals the quiet working section
  await workingPill.click();
  await expect(page.locator(".working-sec")).toContainText("Compile Lean proof on Spark");
  await workingPill.click();

  // Wait for prefetched transcript on m-perm to surface the interactive Approval badge and options
  const permRow = page.locator('[data-inbox-id="m-perm"]');
  await expect(permRow.locator(".inbox-badge")).toHaveText("Approval");
  await expect(permRow.locator(".inbox-summary")).toHaveText("Apply the pending SQLite migration.");
  await expect(permRow.locator(".inbox-perm-code")).toHaveText("sqlx migrate run");

  // Press '1' to approve the permission request on the focused first row
  await page.keyboard.press("1");
  await expect.poll(() => toolResults.length).toBe(1);
  expect(toolResults[0]).toMatchObject({
    tool_call_id: "call-perm-99",
    name: "ui_native_request",
    result: { action: "accept" },
  });

  // Navigate to m-failed and press Shift+R to retry inline
  const failedRow = page.locator('[data-inbox-id="m-failed"]');
  await failedRow.hover();
  await expect(failedRow.locator(".inbox-act-btn.retry")).toContainText("Retry");
  await page.keyboard.press("Shift+KeyR");
  await expect.poll(() => sentMessages.length).toBe(1);
  expect(sentMessages[0]).toEqual({
    id: "m-failed",
    content: "Continue from where you left off.",
  });
  await expect(failedRow).toBeHidden();

  // Navigate to m-question and open inline quick reply with 'r'
  const questionRow = page.locator('[data-inbox-id="m-question"]');
  await questionRow.hover();
  await page.keyboard.press("r");
  const replyInput = questionRow.locator(".inbox-reply-input");
  await expect(replyInput).toBeFocused();
  await replyInput.fill("Use swipe-right with an Undo toast.");
  await replyInput.press("Enter");

  await expect.poll(() => sentMessages.length).toBe(2);
  expect(sentMessages[1]).toEqual({
    id: "m-question",
    content: "Use swipe-right with an Undo toast.",
  });
  // Replied mission immediately leaves the actionable list
  await expect(questionRow).toBeHidden();

  // Verify m-done shows the Task/Outcome digest, grouped child track failure pill, and Space peek preview
  const doneRow = page.locator('[data-inbox-id="m-done"]');
  await expect(doneRow.locator(".inbox-task-text")).toHaveText(
    "Hide the sidebar scroll thumb until hover.",
  );
  await expect(doneRow.locator(".inbox-digest-tag.outcome")).toContainText("Outcome");
  await expect(doneRow.locator(".inbox-child-pill.failed")).toContainText(
    "1 track failed: Track G-4 Proof Closure",
  );
  await doneRow.hover();
  await page.keyboard.press("Space");
  await expect(doneRow.locator(".inbox-peek-drawer")).toBeVisible();
  await expect(doneRow.locator(".inbox-peek-drawer")).toContainText(
    "Hide the sidebar scroll thumb until hover.",
  );
  await page.keyboard.press("Space");
  await expect(doneRow.locator(".inbox-peek-drawer")).toBeHidden();

  // Mark m-done as Done with 'e', then Undo with 'z'
  await page.keyboard.press("e");
  await expect(doneRow).toBeHidden();
  await expect(page.locator(".inbox-undo-toast")).toContainText("Fix sidebar scroll thumb");
  await expect.poll(() => statusUpdates.at(-1)).toEqual({
    id: "m-done",
    status: "acknowledged",
  });

  await page.keyboard.press("z");
  await expect.poll(() => statusUpdates.at(-1)).toEqual({
    id: "m-done",
    status: "paused",
  });
  await expect(doneRow).toBeVisible();

  // Clicking the AI model pill opens Settings -> Inbox (defaulting to builtin/smart)
  const modelPill = page.locator(".inbox-model-pill");
  await expect(modelPill).toContainText("AI · builtin/smart");
  await modelPill.click();
  await expect(page.locator(".settings-body h2")).toHaveText("Inbox");
  await expect(page.getByLabel("Inbox summary model")).toHaveValue("builtin/smart");
});

test("Inbox renders live production missions and projects when ORB_INBOX_PROD=1", async ({ page }) => {
  test.skip(process.env.ORB_INBOX_PROD !== "1", "Opt-in live production verification");
  const { readFileSync } = await import("node:fs");
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");
  const conn = JSON.parse(readFileSync(join(homedir(), ".orb/connection.json"), "utf8")) as {
    api_url: string;
    token: string;
  };
  await page.addInitScript(
    ({ apiUrl, token }) => {
      localStorage.setItem("orb.apiUrl", apiUrl);
      localStorage.setItem("orb.jwt", token);
      localStorage.setItem("orb-theme", "dark");
    },
    { apiUrl: conn.api_url, token: conn.token },
  );

  await page.goto("/");
  const inboxNav = page.locator("#orb-sidebar").getByRole("button", { name: /Inbox/ });
  await expect(inboxNav).toBeVisible({ timeout: 15000 });
  await inboxNav.click();
  await expect(page.locator(".inbox-page h2")).toHaveText("Inbox");
  // Wait for skeleton to finish and real production rows or zero state to appear
  await expect(page.locator(".inbox-skeleton")).toBeHidden({ timeout: 15000 });
  await page.waitForTimeout(1200);
  const outDir = process.env.ORB_SCREENSHOT_DIR;
  if (outDir) {
    await page.screenshot({ path: join(outDir, "orb-desktop-inbox-prod-dark.png") });
    await page.evaluate(() => {
      document.documentElement.dataset.theme = "light";
      localStorage.setItem("orb-theme", "light");
    });
    await page.waitForTimeout(300);
    await page.screenshot({ path: join(outDir, "orb-desktop-inbox-prod-light.png") });
  }
});

