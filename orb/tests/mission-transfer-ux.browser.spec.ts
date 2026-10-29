import { eventPage } from "./eventPageFixture";
import { test, expect } from "@playwright/test";

const OPENCODE_E2BIG =
  "/srv/sandboxed-storage/workspaces/mission-86d91cc3/.sandboxed-sh-opencode-cmd.sh: 2: opencode: Argument list too long";

const FORK_ENVELOPE = `Continue the work from this conversation in a fresh native session.\n\n<fork_context>\n${JSON.stringify({
  source_mission_id: "86d91cc3",
  source_title: "Audit proof pipeline",
  messages: [
    { role: "user", content: "Inspect the proof runner." },
    { role: "assistant", content: "I checked the workspace layout and build targets." },
  ],
})}\n</fork_context>`;

test("immediate OpenCode E2BIG launch failure keeps source unarchived, shows single launch error card without WAITING or Resume, and preserves receipt", async ({ page }) => {
  const source: any = {
    id: "86d91cc3",
    title: "Audit proof pipeline",
    status: "active",
    backend: "codex",
    model_override: "gpt-6-astra",
    project: "test",
    workspace_name: "host",
    history: [
      { role: "user", content: "Inspect the proof runner." },
      { role: "assistant", content: "I checked the workspace layout and build targets." },
    ],
    created_at: "2026-10-29T01:00:00Z",
    updated_at: "2026-10-29T01:05:00Z",
  };
  const destination: any = {
    ...source,
    id: "d65744b9",
    tags: ["fork-of:86d91cc3"],
    backend: "opencode",
    model_override: "builtin/smart",
    status: "active",
    status_message: undefined,
    history: [{ role: "user", content: FORK_ENVELOPE }],
    created_at: "2026-10-29T01:06:00Z",
    updated_at: "2026-10-29T01:06:00Z",
  };

  let forked = false;
  let launchFailed = false;
  const mutations: { path: string; body: any }[] = [];

  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", "dark");
    // Pre-seed a v7 inbox digest with legacy `verdict: "waiting"` to prove TurnRecap never shows WAITING on failed launch.
    localStorage.setItem(
      "orb.inbox.digests.v7",
      JSON.stringify({
        d65744b9: {
          missionId: "d65744b9",
          updatedMs: Date.parse("2026-10-29T01:06:02Z"),
          schemaVersion: 7,
          verdict: "waiting",
          outcome: "Waiting placeholder should never appear",
          suggestions: ["Misleading suggestion"],
        },
      }),
    );
    const perf: any = { cls: 0, longTasks: [], feedbackMs: null, clickAt: null };
    (window as any).__transferPerf = perf;
    new PerformanceObserver(list => {
      for (const entry of list.getEntries() as any[]) {
        if (!entry.hadRecentInput) perf.cls += entry.value ?? 0;
      }
    }).observe({ type: "layout-shift", buffered: true });
    try {
      new PerformanceObserver(list => {
        for (const entry of list.getEntries()) perf.longTasks.push(entry.duration);
      }).observe({ type: "longtask", buffered: true });
    } catch { /* unsupported in some headless modes */ }
    document.addEventListener("click", ev => {
      const target = ev.target as HTMLElement | null;
      if (target?.closest('[data-model="builtin/smart"]')) perf.clickAt = performance.now();
    }, true);
    new MutationObserver(() => {
      if (perf.clickAt !== null && perf.feedbackMs === null) {
        const status = document.querySelector('[role="menu"] [role="status"]');
        if (status?.textContent?.includes("Transferring")) {
          perf.feedbackMs = performance.now() - perf.clickAt;
        }
      }
    }).observe(document, { subtree: true, childList: true, characterData: true });
  });

  await page.route("**/api/**", async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname;
    if (path === "/api/model-routing/chains") {
      return route.fulfill({ json: [{ id: "builtin/smart", name: "Smart (Default)" }] });
    }
    if (req.method() !== "GET") {
      if (path.endsWith("/inbox-digest") || path.endsWith("/opened") || path.includes("/inbox-state/seen/")) {
        return route.fulfill({ json: {} });
      }
      mutations.push({ path, body: req.postDataJSON() });
      if (path === "/api/control/missions/86d91cc3/cancel") {
        await new Promise(r => setTimeout(r, 40));
        source.status = "interrupted";
        return route.fulfill({ json: {} });
      }
      if (path === "/api/control/missions/86d91cc3/fork") {
        forked = true;
        return route.fulfill({ json: destination });
      }
      if (path === "/api/control/missions/86d91cc3/status") {
        source.status = req.postDataJSON().status;
        return route.fulfill({ json: source });
      }
      return route.fulfill({ status: 400 });
    }
    if (path === "/api/control/stream") {
      const missionId = url.searchParams.get("mission_id");
      if (missionId === "d65744b9" && launchFailed) {
        const sse = [
          `event: mission_status_changed\ndata: ${JSON.stringify({ status: "failed", summary: "Model error" })}\n\n`,
          `event: assistant_message\ndata: ${JSON.stringify({ id: "a-fail", content: OPENCODE_E2BIG, success: false })}\n\n`,
        ].join("");
        return route.fulfill({ contentType: "text/event-stream", body: sse });
      }
      return route.fulfill({ contentType: "text/event-stream", body: "" });
    }
    const destEvents = launchFailed
      ? [
          { id: 1, event_id: "u-1", sequence: 1, event_type: "user_message", content: FORK_ENVELOPE, timestamp: "2026-10-29T01:06:00Z" },
          { id: 2, event_id: "s-2", sequence: 2, event_type: "mission_status_changed", content: "Model error", metadata: { status: "failed", summary: "Model error" }, timestamp: "2026-10-29T01:06:01Z" },
          { id: 3, event_id: "a-3", sequence: 3, event_type: "assistant_message", content: OPENCODE_E2BIG, metadata: { success: false }, timestamp: "2026-10-29T01:06:02Z" },
        ]
      : [{ id: 1, event_id: "u-1", sequence: 1, event_type: "user_message", content: FORK_ENVELOPE, timestamp: "2026-10-29T01:06:00Z" }];
    const sourceEvents = [
      { id: 1, event_id: "su-1", sequence: 1, event_type: "user_message", content: "Inspect the proof runner.", timestamp: "2026-10-29T01:00:00Z" },
      { id: 2, event_id: "sa-2", sequence: 2, event_type: "assistant_message", content: "I checked the workspace layout and build targets.", metadata: { success: true }, timestamp: "2026-10-29T01:05:00Z" },
    ];
    const json = path === "/api/projects" ? { projects: [{ slug: "test", title: "Test" }] }
      : path === "/api/backends" ? [{ id: "codex", name: "Codex" }, { id: "opencode", name: "OpenCode" }]
      : path === "/api/providers/backend-models" ? { backends: { codex: [{ value: "gpt-6-astra", label: "GPT-6 Astra" }], opencode: [] } }
      : path === "/api/control/missions" || path.endsWith("/missions") ? (forked ? [source, destination] : [source]).filter(m => m.status !== "acknowledged")
      : path === "/api/control/missions/86d91cc3" ? source
      : path === "/api/control/missions/d65744b9" ? destination
      : path === "/api/control/missions/86d91cc3/events" ? sourceEvents
      : path === "/api/control/missions/d65744b9/events" ? destEvents
      : path.endsWith("/queue") ? []
      : path.endsWith("/crons") ? { jobs: [] }
      : path.endsWith("/files") ? { entries: [] }
      : path === "/api/remote-nodes" ? { nodes: [] }
      : { job: null, runs: [] };
    return route.fulfill(path.endsWith("/events") ? eventPage(route, Array.isArray(json) ? json : []) : { json });
  });

  await page.goto("/");
  await page.locator(".row.project .row-main", { hasText: "Test" }).click();
  await page.getByRole("button", { name: /Audit proof pipeline/ }).click();

  await page.getByRole("button", { name: "Transfer to another agent", exact: true }).click();
  const menu = page.getByRole("menu", { name: "Transfer to another agent", exact: true });
  await menu.getByRole("menuitem", { name: "OpenCode" }).click();
  await page.getByRole("menu", { name: "Choose a model" }).getByRole("menuitem", { name: "Smart (Default)" }).click();

  // Destination opens with Starting OpenCode on host… and folded carried history; source is NOT archived.
  await expect(page.locator(".under-harness")).toHaveText("OpenCode");
  await expect(page.locator('.scroll [role="status"]').first()).toContainText("Starting OpenCode on host…");
  await expect(page.locator(".fork-context summary")).toContainText("2 messages");
  expect(mutations.filter(m => m.path.endsWith("/status"))).toHaveLength(0);

  // Now replay the immediate process-launch failure (`Model error` + `opencode: Argument list too long`).
  launchFailed = true;
  destination.status = "failed";
  destination.status_message = "Model error";
  destination.updated_at = "2026-10-29T01:06:02Z";
  await page.evaluate(() => window.dispatchEvent(new Event("orb:refresh")));

  const notices = page.locator(".scroll .error-notice");
  await expect(notices).toHaveCount(1);
  await expect(notices.first()).toContainText("OpenCode could not start");
  await expect(notices.first()).toContainText("Update the backend");
  await expect(notices.first()).toContainText("without transferring again");
  await expect(notices.first()).not.toContainText("Model error");
  await expect(page.locator(".turn-recap")).toHaveCount(0);
  await expect(page.locator(".scroll")).not.toContainText("WAITING");
  await expect(notices.first().getByRole("button", { name: "Resume" })).toHaveCount(0);

  // Source was NEVER archived.
  expect(mutations.map(m => m.path)).toEqual([
    "/api/control/missions/86d91cc3/cancel",
    "/api/control/missions/86d91cc3/fork",
  ]);

  // Navigate back to the retained original conversation from the recovery action; version disclosure expands cleanly.
  await notices.first().getByRole("button", { name: "Open original conversation" }).click();
  await expect(page.locator(".under-harness")).toHaveText("Codex");
  await expect(page.locator(".row.agent", { hasText: /earlier/i })).toBeVisible();

  // Re-selecting the identical broken OpenCode target reuses the idempotent receipt rather than spawning a duplicate writer.
  await page.getByRole("button", { name: "Transfer to another agent", exact: true }).click();
  await page.getByRole("menu", { name: "Transfer to another agent", exact: true }).getByRole("menuitem", { name: "OpenCode" }).click();
  await page.getByRole("menu", { name: "Choose a model" }).getByRole("menuitem", { name: "Smart (Default)" }).click();
  await expect(page.locator(".under-harness")).toHaveText("OpenCode");
  expect(mutations.filter(m => m.path.endsWith("/fork"))).toHaveLength(1);
  expect(mutations.filter(m => m.path.endsWith("/status"))).toHaveLength(0);

  const perf = await page.evaluate(() => (window as any).__transferPerf);
  console.log("TRANSFER_UX_TRACE", JSON.stringify(perf));
  expect(perf.feedbackMs).not.toBeNull();
  expect(perf.feedbackMs).toBeLessThan(100);
  expect(perf.cls).toBeLessThan(0.02);
  const maxLongTask = perf.longTasks.length ? Math.max(...perf.longTasks) : 0;
  expect(maxLongTask).toBeLessThan(200);
});

test("delayed out-of-order poll and SSE events transition Starting -> Working -> output and archive source once", async ({ page }) => {
  const source: any = {
    id: "src-healthy",
    title: "Healthy transfer",
    status: "interrupted",
    backend: "codex",
    model_override: "gpt-6-astra",
    project: "test",
    workspace_name: "host",
    history: [{ role: "user", content: "Check build" }],
    created_at: "2026-10-29T01:00:00Z",
    updated_at: "2026-10-29T01:00:00Z",
  };
  const destination: any = {
    ...source,
    id: "dst-healthy",
    tags: ["fork-of:src-healthy"],
    backend: "opencode",
    model_override: "builtin/smart",
    status: "pending",
    updated_at: "2026-10-29T01:01:00Z",
  };
  let forked = false;
  let phase: "starting" | "thinking" | "done" = "starting";
  const archiveCalls: any[] = [];

  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", "dark");
  });

  await page.route("**/api/**", async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname;
    if (path === "/api/model-routing/chains") return route.fulfill({ json: [{ id: "builtin/smart", name: "Smart (Default)" }] });
    if (req.method() !== "GET") {
      if (path === "/api/control/missions/src-healthy/fork") { forked = true; return route.fulfill({ json: destination }); }
      if (path === "/api/control/missions/src-healthy/status") {
        archiveCalls.push(req.postDataJSON());
        source.status = req.postDataJSON().status;
        return route.fulfill({ json: source });
      }
      return route.fulfill({ json: {} });
    }
    if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
    const dstEvents = phase === "starting"
      ? [{ id: 1, event_id: "u1", sequence: 1, event_type: "user_message", content: FORK_ENVELOPE, timestamp: "" }]
      : phase === "thinking"
        ? [
            { id: 1, event_id: "u1", sequence: 1, event_type: "user_message", content: FORK_ENVELOPE, timestamp: "" },
            { id: 2, event_id: "t2", sequence: 2, event_type: "tool_call", tool_call_id: "c1", name: "bash", metadata: { args: { command: "ls" } }, timestamp: "" },
          ]
        : [
            { id: 1, event_id: "u1", sequence: 1, event_type: "user_message", content: FORK_ENVELOPE, timestamp: "" },
            { id: 2, event_id: "t2", sequence: 2, event_type: "tool_call", tool_call_id: "c1", name: "bash", metadata: { args: { command: "ls" } }, timestamp: "" },
            { id: 3, event_id: "r3", sequence: 3, event_type: "tool_result", tool_call_id: "c1", name: "bash", content: "Cargo.toml", timestamp: "" },
            { id: 4, event_id: "a4", sequence: 4, event_type: "assistant_message", content: "All checks green.", metadata: { success: true }, timestamp: "" },
          ];
    const json = path === "/api/projects" ? { projects: [{ slug: "test", title: "Test" }] }
      : path === "/api/backends" ? [{ id: "codex", name: "Codex" }, { id: "opencode", name: "OpenCode" }]
      : path === "/api/providers/backend-models" ? { backends: { codex: [{ value: "gpt-6-astra", label: "GPT-6 Astra" }], opencode: [] } }
      : path === "/api/control/missions" || path.endsWith("/missions") ? (forked ? [source, destination] : [source]).filter(m => m.status !== "acknowledged")
      : path === "/api/control/missions/src-healthy" ? source
      : path === "/api/control/missions/dst-healthy" ? destination
      : path === "/api/control/missions/dst-healthy/events" ? dstEvents
      : path.endsWith("/events") || path.endsWith("/queue") ? []
      : path.endsWith("/crons") ? { jobs: [] }
      : path.endsWith("/files") ? { entries: [] }
      : path === "/api/remote-nodes" ? { nodes: [] }
      : { job: null, runs: [] };
    return route.fulfill(path.endsWith("/events") ? eventPage(route, Array.isArray(json) ? json : []) : { json });
  });

  await page.goto("/");
  await page.locator(".row.project .row-main", { hasText: "Test" }).click();
  await page.getByRole("button", { name: /Healthy transfer/ }).click();
  await page.getByRole("button", { name: "Transfer to another agent", exact: true }).click();
  await page.getByRole("menu", { name: "Transfer to another agent", exact: true }).getByRole("menuitem", { name: "OpenCode" }).click();
  await page.getByRole("menu", { name: "Choose a model" }).getByRole("menuitem", { name: "Smart (Default)" }).click();

  await expect(page.locator('.scroll [role="status"]').first()).toContainText("Starting OpenCode on host…");
  expect(archiveCalls).toHaveLength(0);

  // Out-of-order: events report a tool call while mission poll still reports `pending`.
  phase = "thinking";
  await page.evaluate(() => window.dispatchEvent(new Event("orb:refresh")));
  await expect.poll(() => archiveCalls.length).toBe(1);
  expect(archiveCalls[0]).toEqual({ status: "acknowledged" });

  // Later status + completion updates do not trigger duplicate archive calls.
  phase = "done";
  destination.status = "awaiting_user";
  await page.evaluate(() => window.dispatchEvent(new Event("orb:refresh")));
  await expect(page.locator(".st-text")).toContainText("All checks green.");
  expect(archiveCalls).toHaveLength(1);
  await expect(page.locator(".row.agent", { hasText: "Healthy transfer" })).toHaveCount(1);
});
