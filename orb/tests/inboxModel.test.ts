import { describe, expect, it } from "vitest";
import type { Mission, ProjectSummary } from "../src/api";
import {
  buildInboxSections,
  classifyInboxMission,
  clipToSentence,
  extractInboxInteraction,
  formatRelativeTime,
} from "../src/inboxModel";
import type { StreamItem } from "../src/transcriptModel";

const sampleProjects: ProjectSummary[] = [
  { slug: "orb", title: "Orb" },
  { slug: "paloma", title: "Paloma Core" },
];

function makeMission(overrides: Partial<Mission> = {}): Mission {
  return {
    id: "m-1",
    title: "Refactor SSE stream handler",
    status: "completed",
    project: "orb",
    history: [],
    created_at: "2026-10-07T11:00:00Z",
    updated_at: "2026-10-07T11:30:00Z",
    ...overrides,
  };
}

describe("clipToSentence", () => {
  it("strips markdown and keeps the first crisp sentence under the 112-char budget", () => {
    const raw =
      "### Summary\nI updated **`src/stream.ts`** to deduplicate reconnect cursors. I also ran the full Vitest suite and verified all 42 tests pass without regressions.";
    const clipped = clipToSentence(raw);
    expect(clipped).toBe("Summary I updated src/stream.ts to deduplicate reconnect cursors.");
    expect(clipped.length).toBeLessThanOrEqual(112);
  });

  it("clips long single sentences cleanly at a word boundary with an ellipsis", () => {
    const raw =
      "Implemented the unified attention inbox across both desktop and iOS with keyboard navigation and inline permission approvals for background agents";
    const clipped = clipToSentence(raw, 80);
    expect(clipped.endsWith("…")).toBe(true);
    expect(clipped.length).toBeLessThanOrEqual(80);
  });
});

describe("extractInboxInteraction", () => {
  it("extracts permission approvals with 1/2 quick actions from unresolved tools", () => {
    const mission = makeMission({ status: "running" });
    const items: StreamItem[] = [
      {
        kind: "tool",
        key: "t1",
        callId: "call-perm-1",
        name: "ui_native_request",
        done: false,
        args: {
          method: "permission",
          params: {
            tool: "Bash",
            input: {
              command: "cargo test -j 1 --lib",
              description: "Run unit tests in sandboxed_sh.",
            },
          },
        },
      },
    ];
    const interaction = extractInboxInteraction(mission, items);
    expect(interaction).toBeDefined();
    expect(interaction?.kind).toBe("permission");
    expect(interaction?.prompt).toBe("Run unit tests in sandboxed_sh.");
    expect(interaction?.options.map((o) => `${o.key}:${o.label}`)).toEqual([
      "1:Approve",
      "2:Decline",
    ]);
  });

  it("extracts single-question multiple-choice options as 1/2/3 actions", () => {
    const mission = makeMission({ status: "awaiting_user" });
    const items: StreamItem[] = [
      {
        kind: "tool",
        key: "t2",
        callId: "call-q-1",
        name: "AskUserQuestion",
        done: false,
        args: {
          questions: [
            {
              id: "q1",
              question: "Which layout should we use for the iOS switcher?",
              options: [
                { label: "Top segmented pill" },
                { label: "Dedicated tab bar" },
                { label: "Toolbar sheet" },
              ],
            },
          ],
        },
      },
    ];
    const interaction = extractInboxInteraction(mission, items);
    expect(interaction?.kind).toBe("question");
    expect(interaction?.options.map((o) => `${o.key}:${o.label}`)).toEqual([
      "1:Top segmented pill",
      "2:Dedicated tab bar",
      "3:Toolbar sheet",
    ]);
  });
});

describe("classifyInboxMission & buildInboxSections", () => {
  it("keeps running missions quiet in working[] unless they have a pending interaction", () => {
    const quietRunning = makeMission({
      id: "m-running",
      title: "Background indexing",
      status: "running",
      updated_at: "2026-10-07T11:55:00Z",
    });
    const interactiveRunning = makeMission({
      id: "m-perm",
      title: "Deploy migration",
      status: "running",
      updated_at: "2026-10-07T11:50:00Z",
    });
    const waitingUser = makeMission({
      id: "m-wait",
      title: "API schema design",
      status: "awaiting_user",
      history: [{ role: "assistant", content: "Should we expose the new route under /api/control or /api/projects?" }],
      updated_at: "2026-10-07T11:40:00Z",
    });
    const completed = makeMission({
      id: "m-done",
      title: "Fix sidebar scroll",
      status: "completed",
      history: [{ role: "assistant", content: "Fixed the scroll container height and verified on narrow viewports." }],
      updated_at: "2026-10-07T11:30:00Z",
    });
    const archived = makeMission({
      id: "m-arch",
      status: "acknowledged",
    });
    const btw = makeMission({
      id: "m-btw",
      status: "completed",
      tags: ["btw-parent:m-1"],
    });

    expect(classifyInboxMission(quietRunning)).toBe("working");
    expect(classifyInboxMission(archived)).toBe("hidden");
    expect(classifyInboxMission(btw)).toBe("hidden");

    const sections = buildInboxSections(
      [quietRunning, interactiveRunning, waitingUser, completed, archived, btw],
      sampleProjects,
      () => undefined,
      (id) => (id === "m-perm" ? { id: "req-1", method: "permission" } : undefined),
      Date.parse("2026-10-07T12:00:00Z"),
    );

    expect(sections.working.map((i) => i.id)).toEqual(["m-running"]);
    expect(sections.needsYou.map((i) => i.id)).toEqual(["m-perm", "m-wait"]);
    expect(sections.ready.map((i) => i.id)).toEqual(["m-done"]);
    expect(sections.totalActionable).toBe(3);
    expect(sections.needsYou[1].badge).toBe("Question");
    expect(sections.ready[0].summary).toBe(
      "Fixed the scroll container height and verified on narrow viewports.",
    );
  });

  it("formats compact relative times accurately", () => {
    const now = Date.parse("2026-10-07T12:00:00Z");
    expect(formatRelativeTime("2026-10-07T11:59:30Z", now)).toBe("now");
    expect(formatRelativeTime("2026-10-07T11:45:00Z", now)).toBe("15m");
    expect(formatRelativeTime("2026-10-07T09:00:00Z", now)).toBe("3h");
    expect(formatRelativeTime("2026-10-05T12:00:00Z", now)).toBe("2d");
  });

  it("computes unreadCount, filters child subagent workers and unassigned probes, and cleans Rust Some(N) errors", () => {
    const unreadWaiting = makeMission({
      id: "m-unread",
      title: "/goal Orb",
      status: "awaiting_user",
      project: "orb",
      first_viewed_at: null,
      history: [{ role: "assistant", content: "Ready for your review on the new unread filter." }],
      updated_at: "2026-10-07T11:50:00Z",
    });
    const alreadyViewedCompleted = makeMission({
      id: "m-read",
      title: "Earlier completed run",
      status: "completed",
      project: "orb",
      first_viewed_at: "2026-10-07T11:45:00Z",
      last_output_at: "2026-10-07T11:40:00Z",
      updated_at: "2026-10-07T11:40:00Z",
    });
    const subagentWorker = makeMission({
      id: "m-subagent",
      title: "You are a sub-agent working on issue #1534",
      status: "completed",
      project: "orb",
      parent_mission_id: "m-unread",
      tags: ["worker-dispatch:issue-1534"],
    });
    const unassignedProbe = makeMission({
      id: "m-probe",
      title: "Reply with only PONG.",
      status: "completed",
      project: null,
    });
    const rustErrorMission = makeMission({
      id: "m-rust-err",
      title: "Keep working on #1534",
      status: "failed",
      project: "paloma",
      terminal_reason: "opencode turn failed: error: command exited with Some(1)",
      updated_at: "2026-10-07T11:48:00Z",
    });

    const sections = buildInboxSections(
      [unreadWaiting, alreadyViewedCompleted, subagentWorker, unassignedProbe, rustErrorMission],
      sampleProjects,
      () => undefined,
      () => undefined,
      Date.parse("2026-10-07T12:00:00Z"),
    );

    // Subagent worker and unassigned probe are excluded
    const allIds = [...sections.needsYou, ...sections.ready].map((i) => i.id);
    expect(allIds).toEqual(["m-rust-err", "m-unread", "m-read"]);

    // Unread vs read tracking
    const unreadItem = sections.needsYou.find((i) => i.id === "m-unread")!;
    const readItem = sections.ready.find((i) => i.id === "m-read")!;
    expect(unreadItem.unread).toBe(true);
    expect(readItem.unread).toBe(false);
    expect(sections.unreadCount).toBe(2); // m-unread + m-rust-err
    expect(sections.attentionCount).toBe(1); // m-rust-err (failed)

    // Deduplicated headline when goal title matches project title ("Orb" + "/goal Orb")
    expect(unreadItem.isGoal).toBe(true);
    expect(unreadItem.headline).toBe("Orb objective");

    // Cleaned Rust Some(1) error text
    const errItem = sections.needsYou.find((i) => i.id === "m-rust-err")!;
    expect(errItem.summary).not.toContain("Some(1)");
  });

  it("does not mark an active mission as read before it completes its turn", async () => {
    const { isMissionUnread, markMissionRead } = await import("../src/missionUnread");
    const activeMission = makeMission({
      id: "d04c77b2-7028-4c03-b7c1-ab20b818e0f3",
      title: "Pareto",
      status: "active",
      project: "verity-core",
      first_viewed_at: null,
      last_output_at: "2026-10-07T14:00:35Z",
      updated_at: "2026-10-07T14:00:35Z",
    });

    // Opening the mission while it is still active should not consume its unread state
    markMissionRead(activeMission);

    const completedMission: Mission = {
      ...activeMission,
      status: "completed",
      updated_at: "2026-10-07T14:30:35Z",
      history: [
        {
          role: "assistant",
          content: "I will wait for the background build task to notify me when it finishes.",
        },
      ],
    };

    expect(isMissionUnread(completedMission)).toBe(true);
    markMissionRead(completedMission);
    expect(isMissionUnread(completedMission)).toBe(false);
  });

  it("attaches childSummary to parent orchestrator missions and surfaces unread child track failures", () => {
    const parentPareto = makeMission({
      id: "d04c77b2-7028-4c03-b7c1-ab20b818e0f3",
      title: "Pareto",
      status: "completed",
      project: "orb",
      first_viewed_at: "2026-10-07T14:22:16Z",
      updated_at: "2026-10-07T14:00:35Z",
      history: [
        { role: "user", content: "Launch the 3 verification tracks." },
        { role: "assistant", content: "Dispatched Track INV-1, Track G-2, and Track G-4." },
      ],
    });
    const childOk = makeMission({
      id: "child-ok",
      title: "Track INV-1",
      status: "completed",
      project: "orb",
      parent_mission_id: parentPareto.id,
      first_viewed_at: "2026-10-07T14:10:00Z",
      updated_at: "2026-10-07T14:05:00Z",
    });
    const childFailedUnread = makeMission({
      id: "child-fail",
      title: "Track G-4 (CLAIM-1) Proof Closure",
      status: "failed",
      project: "orb",
      parent_mission_id: parentPareto.id,
      first_viewed_at: null,
      updated_at: "2026-10-07T14:25:00Z",
    });

    const sections = buildInboxSections(
      [parentPareto, childOk, childFailedUnread],
      sampleProjects,
      () => undefined,
      () => undefined,
      Date.parse("2026-10-07T14:30:00Z"),
    );

    // Child missions themselves are hidden from top-level rows, but grouped onto parentPareto
    expect(sections.ready.map((i) => i.id)).toEqual([parentPareto.id]);
    const parentItem = sections.ready[0];
    expect(parentItem.childSummary).toBeDefined();
    expect(parentItem.childSummary?.total).toBe(2);
    expect(parentItem.childSummary?.completed).toBe(1);
    expect(parentItem.childSummary?.failed).toBe(1);
    expect(parentItem.childSummary?.failedChildren[0].title).toBe("Track G-4 (CLAIM-1) Proof Closure");
    expect(parentItem.childSummary?.hasUnreadFailure).toBe(true);
    // Parent surfaces in Unread and Attention because a child track failed unread
    expect(parentItem.unread).toBe(true);
    expect(parentItem.attention).toBe(true);
    expect(sections.unreadCount).toBe(1);
    expect(sections.attentionCount).toBe(1);
    expect(parentItem.peekTurns.map((t) => `${t.role}:${t.text}`)).toEqual([
      "user:Launch the 3 verification tracks.",
      "assistant:Dispatched Track INV-1, Track G-2, and Track G-4.",
    ]);
  });

  it("preserves full Markdown code fences in peekTurns, attaches tool workReceipts, and extracts lastRequest/outcome", async () => {
    const { buildDigestSnapshot, parseDigestJson } = await import("../src/inboxDigest");
    const { inboxConfig, saveInboxConfig } = await import("../src/inboxSettings");

    const sparkMission = makeMission({
      id: "m-spark",
      title: "DGX Spark",
      status: "completed",
      project: "paloma",
      updated_at: "2026-10-07T15:30:00Z",
    });

    const items: StreamItem[] = [
      {
        kind: "user",
        key: "u1",
        text: 'just give me the edited:\n```json\n{\n  "ssh": [{ "action": "accept", "src": ["autogroup:member"] }]\n}\n```',
      },
      {
        kind: "tool",
        key: "t1",
        callId: "c1",
        name: "edit",
        done: true,
        args: { file_path: "/etc/tailscale/policy.hujson" },
      },
      {
        kind: "tool",
        key: "t2",
        callId: "c2",
        name: "bash",
        done: true,
        args: { command: "tailscale status" },
      },
      {
        kind: "text",
        key: "a1",
        text: 'Here\'s the edited policy.\n```json\n{\n  "ssh": [\n    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot", "root"] }\n  ]\n}\n```',
      },
    ];

    const sections = buildInboxSections(
      [sparkMission],
      sampleProjects,
      () => items,
      () => undefined,
      Date.parse("2026-10-07T15:35:00Z"),
    );

    const row = sections.ready[0];
    expect(row.lastRequest).toContain("just give me the edited:");
    expect(row.lastRequest).toContain("json:");
    expect(row.summary).toContain("Here's the edited policy.");
    expect(row.summary).toContain("json:");
    expect(row.workReceiptSummary).toBe("1 command · Edited 1 file");
    expect(row.verdict).toBe("succeeded");

    // Peek turns preserve unstripped Markdown (code blocks intact) and attach tool work receipts
    expect(row.allPeekTurns).toHaveLength(2);
    expect(row.allPeekTurns[0].markdown).toContain("```json");
    expect(row.allPeekTurns[1].markdown).toContain('"users": ["autogroup:nonroot", "root"]');
    expect(row.allPeekTurns[1].workReceipt?.summary).toBe("1 command · Edited 1 file");
    expect(row.allPeekTurns[1].workReceipt?.details).toEqual([
      "edit tailscale/policy.hujson",
      "bash: tailscale status",
    ]);

    // Digest snapshot and JSON parser
    const snapshot = buildDigestSnapshot(sparkMission, items);
    expect(snapshot).toContain("Tools executed in latest turn: 1 command · Edited 1 file");
    const parsed = parseDigestJson(
      '{"task":"Update Tailscale SSH ACL policy for cross-member access","outcome":"Generated updated JSON ACL policy replacing autogroup:self with autogroup:member","verdict":"succeeded"}',
      row.updatedMs,
      "builtin/smart",
    );
    expect(parsed?.task).toBe("Update Tailscale SSH ACL policy for cross-member access");
    expect(parsed?.outcome).toContain("Generated updated JSON ACL policy");
    expect(parsed?.verdict).toBe("succeeded");
    expect(parsed?.model).toBe("builtin/smart");

    // Inbox settings default to builtin/smart and persist changes
    expect(inboxConfig().model).toBe("builtin/smart");
    expect(inboxConfig().aiSummary).toBe(true);
    saveInboxConfig({ aiSummary: true, model: "builtin/fast" });
    expect(inboxConfig().model).toBe("builtin/fast");
    saveInboxConfig({ aiSummary: true, model: "builtin/smart" });
  });

  it("strips noisy codex_app_server diagnostics and avoids duplicate error turns in peek", () => {
    const blockedVerity = makeMission({
      id: "m-verity",
      title: "/goal Complete the existing lfglabs-dev/verity roadmap",
      goal_mode: true,
      goal_objective: "Complete the existing lfglabs-dev/verity roadmap",
      status: "blocked",
      project: "orb",
      status_message:
        "Native Codex goal stopped with status 'paused'; the objective and counters are preserved. Resume after resolving that stop.\n\ndiagnostics: 2026-10-07T16:10:33.000520Z ERROR codex_app_server: Project-local config, hooks, and exec policies are disabled in the following folders until the project is trusted",
      history: [
        {
          role: "assistant",
          content:
            "All 10 PRs are merged and all roadmap deliverables verified. Work and validation receipts are preserved.",
        },
      ],
    });

    const sections = buildInboxSections(
      [blockedVerity],
      sampleProjects,
      () => undefined,
      () => undefined,
      Date.parse("2026-10-07T16:25:00Z"),
    );

    const item = sections.needsYou[0];
    // goal_objective is not duplicated into lastRequest when there is no distinct user message
    expect(item.lastRequest).toBeUndefined();
    expect(item.allPeekTurns).toHaveLength(2);
    expect(item.allPeekTurns[0].role).toBe("assistant");
    expect(item.allPeekTurns[1].role).toBe("error");
    expect(item.allPeekTurns[1].markdown).not.toContain("codex_app_server");
    expect(item.allPeekTurns[1].markdown).toContain(
      "Native Codex goal stopped with status 'paused'",
    );
  });

  it("filters out [Automatic resume after a usage limit] from lastRequest and preserves multi-sentence overviews", () => {
    const resumedMission = makeMission({
      id: "m-resumed",
      title: "Fix the remaining data-processing and display bugs",
      status: "completed",
      project: "orb",
      history: [
        { role: "user", content: "Run the iOS Simulator stability tests on air-2." },
        {
          role: "user",
          content:
            "[Automatic resume after a usage limit] Antigravity background task handoff stopped your previous turn.",
        },
        {
          role: "assistant",
          content:
            "Les tests iOS Simulator (StabilityTests : 37 exécutés, 0 échec) sont passés sur air-2. Les correctifs de traitement de données ont été vérifiés sans régression.",
        },
      ],
    });

    const sections = buildInboxSections(
      [resumedMission],
      sampleProjects,
      () => undefined,
      () => undefined,
      Date.parse("2026-10-07T18:30:00Z"),
    );

    const item = sections.ready[0];
    expect(item.lastRequest).toBe("Run the iOS Simulator stability tests on air-2.");
    expect(item.summary).toContain("37 exécutés, 0 échec");
    expect(item.summary).toContain("sans régression.");
    expect(item.allPeekTurns.map((t) => t.role)).toEqual(["user", "assistant"]);
  });

  it("merges long error-kind assistant messages in Peek, synthesizes initial prompt when >200 tools push user_message out, and cleans child fork narration", () => {
    const parent = makeMission({
      id: "m-parent-verity",
      title: "Implement a fully self-contained local-agent runner",
      goal_mode: true,
      goal_objective: "Implement a fully self-contained local-agent runner for Orb",
      status: "completed",
      project: "orb",
      history: [],
    });
    const failedFork = makeMission({
      id: "m-child-narration",
      title:
        "I’ll read the updated objective file, then check the current worktree and running validations befo... · fork",
      status: "failed",
      project: "orb",
      parent_mission_id: "m-parent-verity",
    });
    const runningFork = makeMission({
      id: "m-child-running",
      title: "Verity · fork",
      status: "active",
      project: "orb",
      parent_mission_id: "m-parent-verity",
    });

    const streamItems: StreamItem[] = [
      {
        kind: "tool",
        id: "t-1",
        name: "bash",
        input: '{"command":"cargo test"}',
        output: "ok",
        done: true,
      },
      {
        kind: "text",
        id: "a-1",
        text: "I'll stop work and pause the existing goal now.",
      },
      {
        kind: "error",
        id: "e-long",
        text: "All 10 PRs are merged and all roadmap deliverables verified across 64 tests (`verity-core`, `verity-compiler`, and `verity-edsl`). The clean Pareto coverage check passed with zero regressions and worktree receipts are preserved.",
      },
    ];

    const sections = buildInboxSections(
      [parent, failedFork, runningFork],
      sampleProjects,
      (id) => (id === "m-parent-verity" ? streamItems : undefined),
      () => undefined,
      Date.parse("2026-10-07T19:30:00Z"),
    );

    const item = sections.ready[0];
    expect(item.allPeekTurns.map((t) => t.role)).toEqual(["user", "assistant"]);
    expect(item.allPeekTurns[0].markdown).toContain(
      "Implement a fully self-contained local-agent runner for Orb",
    );
    expect(item.allPeekTurns[1].markdown).toContain("All 10 PRs are merged");
    expect(item.childSummary?.failedChildren[0]?.title).toBe("fork");
    expect(item.childSummary?.running).toBe(1);
  });

  it("condenses long verbose mission titles and supports stale-while-revalidate AI digest goal & outcome", async () => {
    const { condenseMissionHeadline } = await import("../src/inboxModel");
    const { getCachedInboxDigest, getExactCachedInboxDigest, parseDigestJson, storeInboxDigest } =
      await import("../src/inboxDigest");

    const condensed = condenseMissionHeadline(
      "/goal Complete the existing lfglabs-dev/verity solidity_import mission, with the remaining 18 functions and EVM parity checks",
      "Verity",
    );
    expect(condensed).toBe("Solidity_import");
    expect(condensed.length).toBeLessThanOrEqual(58);

    const parsed = parseDigestJson(
      '{"goal":"Morpho Midnight Solidity Import & EVM Parity","task":"Report current status, remaining work, and pause the goal","outcome":"Paused the goal at 27/45 functions (60%) with byte locals and Yul addition pushed.","verdict":"waiting"}',
      1000,
      "builtin/smart",
    );
    expect(parsed?.goal).toBe("Morpho Midnight Solidity Import & EVM Parity");
    expect(parsed?.task).toBe("Report current status, remaining work, and pause the goal");
    expect(parsed?.verdict).toBe("waiting");

    storeInboxDigest("m-swr-test", 1000, "builtin/smart", parsed!);
    // Exact lookup hits for 1000, misses for 2000
    expect(getExactCachedInboxDigest("m-swr-test", 1000, "builtin/smart")?.goal).toBe(
      "Morpho Midnight Solidity Import & EVM Parity",
    );
    expect(getExactCachedInboxDigest("m-swr-test", 2000, "builtin/smart")).toBeUndefined();
    // Stale-while-revalidate lookup returns the 1000 digest on frame 1 even when updatedMs advances to 2000
    expect(getCachedInboxDigest("m-swr-test", 2000, "builtin/smart")?.goal).toBe(
      "Morpho Midnight Solidity Import & EVM Parity",
    );
  });

  it("strips [Image #N] and [Uploaded: ...] from lastRequest while preserving raw StreamItem references for Transcript in buildPeekStreamItems", async () => {
    const { buildPeekStreamItems, extractLastRequest } = await import("../src/inboxModel");

    const imgMission = makeMission({
      id: "m-img-peek",
      title: "Tu travailles sur l'ORB, enfin anciennement sandbox.sh",
      status: "completed",
      project: "orb",
    });

    const userItem: StreamItem = {
      kind: "user",
      key: "u-img-1",
      text: "[Image #1] Lorsque j'ajoute une image dans l'application de bureau, cela devrait aussi m'ajouter l'image comme dans un bloc.\n\n[Image #1] [Uploaded: /root/.sandboxed-sh/uploads/core/1775647709226-image.png]\n\n<!-- paloma:attachment:11111111-2222-3333-4444-555555555555 -->\nAttached context:\n- File: orb/src/Composer.tsx",
    };
    const toolItem: StreamItem = {
      kind: "tool",
      key: "t-img-1",
      callId: "c-img-1",
      name: "edit",
      done: true,
      args: { file_path: "orb/src/Composer.tsx" },
    };
    const assistantItem: StreamItem = {
      kind: "text",
      key: "a-img-1",
      text: "C'est fait dans `orb/src/Composer.tsx` : l'image collée affiche désormais la miniature.",
      live: false,
    };

    const req = extractLastRequest(imgMission, [userItem, toolItem, assistantItem]);
    expect(req).toBe(
      "Lorsque j'ajoute une image dans l'application de bureau, cela devrait aussi m'ajouter l'image comme dans un bloc.",
    );
    expect(req).not.toContain("[Image #1]");
    expect(req).not.toContain("[Uploaded:");

    const peek = buildPeekStreamItems(imgMission, [userItem, toolItem, assistantItem], "", false);
    expect(peek.hiddenTurnCount).toBe(0);
    expect(peek.items).toHaveLength(3);
    // Exact object identity is preserved so Solid's Transcript store reconciliation does not remount DOM nodes
    expect(peek.items[0]).toBe(userItem);
    expect(peek.items[1]).toBe(toolItem);
    expect(peek.items[2]).toBe(assistantItem);
  });
});

