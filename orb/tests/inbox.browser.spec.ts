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
      created_at: "2026-04-17T11:50:00Z",
      updated_at: "2026-04-17T11:58:00Z",
    },
    {
      id: "m-perm",
      title: "Migrate mission schema",
      status: "running",
      project: "orb",
      backend: "claudecode",
      history: [],
      created_at: "2026-04-17T11:40:00Z",
      updated_at: "2026-04-17T11:56:00Z",
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
      created_at: "2026-04-17T11:20:00Z",
      updated_at: "2026-04-17T11:52:00Z",
    },
    {
      id: "m-failed",
      title: "CTRL-G Docker/Lean inspection",
      status: "failed",
      project: "paloma",
      backend: "claudecode",
      terminal_reason: "Docker daemon unreachable in host workspace.",
      created_at: "2026-04-17T11:10:00Z",
      updated_at: "2026-04-17T11:51:00Z",
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
      created_at: "2026-04-17T10:00:00Z",
      updated_at: "2026-04-17T11:30:00Z",
    },
    {
      id: "m-child-fail",
      title: "Track G-4 Proof Closure",
      status: "failed",
      project: "paloma",
      parent_mission_id: "m-done",
      created_at: "2026-04-17T11:25:00Z",
      updated_at: "2026-04-17T11:32:00Z",
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
      if (target) {
        target.status = "running";
        target.history = [
          ...(target.history ?? []),
          { role: "user", content: body.content },
        ];
      }
      await route.fulfill({ json: { id: "msg-1", queued: false } });
      return;
    }

    if (path === "/api/control/stream" && req.method() === "GET") {
      const mid = url.searchParams.get("mission");
      if (mid === "m-question" && sentMessages.some((m) => m.id === "m-question")) {
        const sseBody = [
          `event: text_delta\ndata: ${JSON.stringify({ content: "Implemented swipe-right with Undo toast.", sequence: 10 })}\n\n`,
          `event: assistant_message\ndata: ${JSON.stringify({ content: "Implemented swipe-right with Undo toast.", sequence: 11 })}\n\n`,
        ].join("");
        await route.fulfill({
          status: 200,
          headers: { "Content-Type": "text/event-stream" },
          body: sseBody,
        });
        return;
      }
      await route.fulfill({
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
        body: "",
      });
      return;
    }

    await route.fulfill({ json: {} });
  });

  await page.goto("/");

  // Sidebar shows Inbox with actionable badge count (4: m-perm, m-question, m-failed, m-done; m-working & m-child-fail are quiet/grouped)
  const inboxNav = page.locator("#orb-sidebar").getByRole("button", { name: /Inbox/ });
  await expect(inboxNav).toBeVisible({ timeout: 15000 });
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

  // Navigate to m-question and open unified Peek & Reply drawer with 'r'
  const questionRow = page.locator('[data-inbox-id="m-question"]');
  await questionRow.hover();
  // Verify there is no duplicate unread dot inside the row next to the project dot
  await expect(questionRow.locator(".inbox-unread-dot")).toHaveCount(0);
  await expect(questionRow.locator(".inbox-project-dot")).toHaveCount(1);
  // Verify keyboard shortcut badges are visible on row actions
  await expect(questionRow.locator(".inbox-act-btn", { hasText: "Peek & Reply" }).locator("kbd")).toHaveText("Space");
  await expect(questionRow.locator(".inbox-act-btn.done").locator("kbd")).toHaveText("E");

  await page.keyboard.press("r");
  await expect(questionRow.locator(".inbox-peek-drawer")).toBeVisible();
  await expect(questionRow.locator(".inbox-peek-status-card")).toContainText("Should swipe-right mark the conversation as Done");
  await expect(questionRow.locator(".inbox-peek-composer .composer")).toBeVisible();
  await expect(questionRow.locator(".inbox-peek-composer .plus")).toBeVisible();
  const replyInput = questionRow.locator(".inbox-peek-composer textarea");
  await expect(replyInput).toBeFocused();
  await replyInput.fill("Use swipe-right with an Undo toast.");
  await expect(questionRow.locator(".inbox-peek-composer .send")).toBeVisible();
  await replyInput.press("Enter");

  await expect.poll(() => sentMessages.length).toBe(2);
  expect(sentMessages[1]).toEqual({
    id: "m-question",
    content: "Use swipe-right with an Undo toast.",
  });
  // Peek drawer stays open after sending a message, row transitions from unread to read in-place,
  // and both the sent user message and live-streamed assistant response appear inside Peek
  await expect(questionRow).toBeVisible();
  await expect(questionRow.locator(".inbox-peek-drawer")).toBeVisible();
  await expect(questionRow).toHaveAttribute("data-inbox-unread", "false");
  await expect(questionRow.locator(".inbox-peek-transcript .user").last()).toContainText(
    "Use swipe-right with an Undo toast.",
  );
  await expect(questionRow.locator(".inbox-peek-transcript .st-text").last()).toContainText(
    "Implemented swipe-right with Undo toast.",
  );
  // Close the Peek drawer on m-question with Escape
  await replyInput.press("Escape");
  await expect(questionRow.locator(".inbox-peek-drawer")).toBeHidden();

  // Verify m-done shows the Asked/outcome overview, omits redundant Completed badge, shows failed child track pill, and supports Space unified peek & reply preview
  const doneRow = page.locator('[data-inbox-id="m-done"]');
  await expect(doneRow.locator(".inbox-task-text")).toHaveText(
    "Hide the sidebar scroll thumb until hover.",
  );
  await expect(doneRow.locator(".inbox-badge")).toHaveCount(0);
  await expect(doneRow.locator(".inbox-summary")).toContainText(
    "Updated the scroll thumb track to remain hidden until pointer hover and verified all Playwright checks pass.",
  );
  await expect(doneRow.locator(".inbox-child-pill.failed")).toContainText(
    "1 track failed: Track G-4 Proof Closure",
  );
  await doneRow.hover();

  // Verify the triage toolbar sits in the header row and never overlaps the summary or task text
  const toolbarBox = await doneRow.locator(".inbox-triage-btns").boundingBox();
  const summaryBox = await doneRow.locator(".inbox-summary").boundingBox();
  expect(toolbarBox).not.toBeNull();
  expect(summaryBox).not.toBeNull();
  expect(toolbarBox!.y + toolbarBox!.height).toBeLessThanOrEqual(summaryBox!.y + 4);

  await page.keyboard.press("Space");
  await expect(doneRow.locator(".inbox-peek-drawer")).toBeVisible();
  await expect(doneRow.locator(".inbox-peek-transcript .user")).toContainText(
    "Hide the sidebar scroll thumb until hover.",
  );
  // Verify there is no legacy vertical .inbox-peek-role.user box
  await expect(doneRow.locator(".inbox-peek-role")).toHaveCount(0);
  await expect(doneRow.locator(".inbox-peek-transcript .st-text")).toContainText(
    "Updated the scroll thumb track to remain hidden",
  );
  await expect(doneRow.locator(".inbox-peek-status-card")).toContainText(
    "Updated the scroll thumb track to remain hidden",
  );
  // Verify the Peek scroll container is anchored to the bottom on open
  const scrollMetrics = await doneRow.locator(".inbox-peek-scroll").evaluate((el) => ({
    scrollTop: el.scrollTop,
    clientHeight: el.clientHeight,
    scrollHeight: el.scrollHeight,
  }));
  expect(scrollMetrics.scrollTop + scrollMetrics.clientHeight).toBeGreaterThanOrEqual(
    scrollMetrics.scrollHeight - 8,
  );
  await page.keyboard.press("Escape");
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

test("Inbox Peek renders shared Transcript with inline images, attached context, WorkFold, and bottom-anchored scroll without reset on poll", async ({
  page,
}) => {
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test-token");
    localStorage.setItem("orb-theme", "dark");
  });

  const tinyPngDataUrl =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

  const userPrompt = [
    "[Image #1] Lorsque j'ajoute une image dans l'application de bureau, cela devrait aussi m'ajouter l'image comme dans un bloc.",
    "",
    `[Image #1] [Uploaded: ${tinyPngDataUrl}]`,
    "",
    "<!-- paloma:attachment:11111111-2222-3333-4444-555555555555 -->",
    "Attached context: read `.paloma/messages/11111111-2222-3333-4444-555555555555/.paloma/attach.md` (paths in that manifest are relative to `.paloma/messages/11111111-2222-3333-4444-555555555555`).",
  ].join("\n");

  const longAssistantReply = [
    "### Analyse & Correctif",
    "",
    "1. Réutilisation du composant `<Transcript>` dans `orb/src/Inbox.tsx` afin de partager exactement le rendu de `MissionView`.",
    "2. Prise en charge native des miniatures `<MessageImage>` avec `<Lightbox>` et du badge `Attached context`.",
    "3. Ancrage du scroll en bas à l'ouverture sur le dernier message et suppression des remounts DOM lors des polls.",
    "",
    "```tsx",
    "export function renderPeekTranscript(items: StreamItem[]) {",
    "  return <Transcript items={items} />;",
    "}",
    "```",
    "",
    "Paragraphe supplémentaire 1 pour dépasser la hauteur de 360px du conteneur de défilement et vérifier que le scroll démarre bien tout en bas.",
    "",
    "Paragraphe supplémentaire 2 : toutes les vérifications unitaires et navigateur passent sans aucun clignotement.",
    "",
    "Paragraphe final visible tout en bas du tiroir Peek.",
  ].join("\n");

  const missions = [
    {
      id: "m-peek-rich",
      title: "Tu travailles sur l'ORB, enfin anciennement sandbox.sh",
      status: "completed",
      project: "orb",
      backend: "claudecode",
      history: [
        { role: "user", content: userPrompt },
        { role: "assistant", content: longAssistantReply },
      ],
      created_at: "2026-10-08T12:00:00Z",
      updated_at: "2026-10-08T12:30:00Z",
    },
  ];

  await page.route("**/api/**", async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    const path = url.pathname;

    if (path === "/api/projects") {
      await route.fulfill({
        json: { projects: [{ slug: "orb", title: "Sandboxed", color: "blue" }] },
      });
      return;
    }
    if (path === "/api/control/missions" && req.method() === "GET") {
      await route.fulfill({ json: missions });
      return;
    }
    if (path === "/api/control/missions/m-peek-rich/events") {
      await route.fulfill({
        headers: {
          "X-Orb-Events-Protocol": "1",
          "X-Has-More": "false",
          "X-Next-Cursor": "3",
          "X-Page-Max-Sequence": "3",
          "X-Max-Sequence": "3",
        },
        json: [
          {
            id: 1,
            sequence: 1,
            event_type: "user_message",
            timestamp: "2026-10-08T12:00:00Z",
            content: userPrompt,
          },
          {
            id: 2,
            sequence: 2,
            event_type: "tool_call",
            timestamp: "2026-10-08T12:05:00Z",
            tool_call_id: "call-edit-1",
            tool_name: "Edit",
            content: JSON.stringify({ file_path: "orb/src/Inbox.tsx" }),
          },
          {
            id: 3,
            sequence: 3,
            event_type: "tool_result",
            timestamp: "2026-10-08T12:05:02Z",
            tool_call_id: "call-edit-1",
            tool_name: "Edit",
            content: "ok",
          },
          {
            id: 4,
            sequence: 4,
            event_type: "agent_message",
            timestamp: "2026-10-08T12:30:00Z",
            content: longAssistantReply,
          },
        ],
      });
      return;
    }
    if (path.endsWith("/queue") && req.method() === "GET") {
      await route.fulfill({ json: [] });
      return;
    }
    await route.fulfill({ json: {} });
  });

  await page.goto("/");
  const inboxNav = page.locator("#orb-sidebar").getByRole("button", { name: /Inbox/ });
  await expect(inboxNav).toBeVisible({ timeout: 15000 });
  await page.keyboard.press("Meta+KeyI");
  const row = page.locator('[data-inbox-id="m-peek-rich"]');
  await expect(row).toBeVisible();

  // Verify legacy "Sandboxed" project title for slug "orb" is normalized to "Orb"
  await expect(row.locator(".inbox-project-name")).toHaveText("Orb");

  // Verify the Asked row stripped [Image #1] and [Uploaded: ...] cleanly
  await expect(row.locator(".inbox-task-text")).toContainText(
    "Lorsque j'ajoute une image dans l'application de bureau",
  );
  await expect(row.locator(".inbox-task-text")).not.toContainText("[Uploaded:");

  // Open Peek drawer
  await row.hover();
  await page.keyboard.press("Space");
  const drawer = row.locator(".inbox-peek-drawer");
  await expect(drawer).toBeVisible();

  // Verify shared Composer is rendered inside Peek with "Send follow-up" placeholder and + attachment button
  const composer = drawer.locator(".inbox-peek-composer .composer");
  await expect(composer).toBeVisible();
  await expect(composer.locator(".plus")).toBeVisible();
  await expect(composer.locator("textarea")).toHaveAttribute("placeholder", /Send follow-up/);

  // Verify outer .inbox-page does not become unnecessarily scrollable when a single Peek card is open
  const pageScrollMetrics = await page.locator(".inbox-page").evaluate((el) => ({
    scrollHeight: el.scrollHeight,
    clientHeight: el.clientHeight,
  }));
  expect(pageScrollMetrics.scrollHeight).toBeLessThanOrEqual(pageScrollMetrics.clientHeight);

  // Verify shared Transcript elements render: .user bubble, .message-image thumbnail, .user-context badge, .st-work fold, and .st-text Markdown
  const userBubble = drawer.locator(".inbox-peek-transcript .user");
  await expect(userBubble).toBeVisible();
  await expect(userBubble.locator(".message-image img")).toBeVisible();
  await expect(userBubble.locator(".message-image span")).toHaveText("#1");
  await expect(userBubble.locator(".user-context")).toHaveText("Attached context");
  await expect(drawer.locator(".inbox-peek-transcript .st-work")).toContainText("Edited 1 file");
  await expect(drawer.locator(".inbox-peek-transcript .st-text")).toContainText(
    "Paragraphe final visible tout en bas du tiroir Peek.",
  );

  // Verify scroll started at the bottom (on the latest message)
  const scroller = drawer.locator(".inbox-peek-scroll");
  await expect
    .poll(async () => {
      const m = await scroller.evaluate((el) => ({
        top: el.scrollTop,
        ch: el.clientHeight,
        sh: el.scrollHeight,
      }));
      return m.sh > m.ch && m.top + m.ch >= m.sh - 8;
    })
    .toBe(true);

  if (process.env.ORB_SCREENSHOT_DIR) {
    await page.screenshot({
      path: `${process.env.ORB_SCREENSHOT_DIR}/orb-desktop-inbox-rich-peek.png`,
    });
  }

  // Tag the DOM node inside .inbox-peek-transcript, scroll up to 40px, and wait across a 5.5s poll cycle
  // to verify neither DOM identity nor scrollTop resets/blinks.
  await scroller.evaluate((el) => {
    (el.querySelector(".user") as HTMLElement & { __peekTag?: string }).__peekTag = "alive";
    el.scrollTop = 40;
    el.dispatchEvent(new Event("scroll"));
  });
  await page.waitForTimeout(5500);
  const afterPoll = await scroller.evaluate((el) => ({
    scrollTop: el.scrollTop,
    tag: (el.querySelector(".user") as HTMLElement & { __peekTag?: string })?.__peekTag,
  }));
  expect(afterPoll.tag).toBe("alive");
  expect(afterPoll.scrollTop).toBe(40);

  if (process.env.ORB_SCREENSHOT_DIR) {
    await scroller.evaluate((el) => {
      el.scrollTop = 0;
    });
    await page.screenshot({
      path: `${process.env.ORB_SCREENSHOT_DIR}/orb-desktop-inbox-rich-peek-top.png`,
    });
  }
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
  await page
    .locator('.inbox-summary[title^="AI Overview"]')
    .first()
    .waitFor({ state: "attached", timeout: 12000 })
    .catch(() => {});
  await page.waitForTimeout(4500);
  const outDir = process.env.ORB_SCREENSHOT_DIR;
  if (outDir) {
    await page.screenshot({ path: join(outDir, "orb-desktop-inbox-prod-dark.png") });
    const firstRow = page.locator(".inbox-row").first();
    if ((await firstRow.count()) > 0) {
      await firstRow.hover();
      await firstRow.locator(".inbox-act-btn", { hasText: "Peek & Reply" }).click();
      await expect(firstRow.locator(".inbox-peek-drawer")).toBeVisible();
      await page.waitForTimeout(500);
      await page.screenshot({ path: join(outDir, "orb-desktop-inbox-prod-peek.png") });
      await firstRow.locator(".inbox-act-btn", { hasText: "Close" }).click();
    }
    await page.evaluate(() => {
      document.documentElement.dataset.theme = "light";
      localStorage.setItem("orb-theme", "light");
    });
    await page.waitForTimeout(300);
    await page.screenshot({ path: join(outDir, "orb-desktop-inbox-prod-light.png") });
  }
});

