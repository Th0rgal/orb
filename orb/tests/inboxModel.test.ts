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
});

