import { describe, expect, it } from "vitest";
import { fireEvent, render, screen } from "@solidjs/testing-library";
import type { Mission } from "../src/api";
import { buildInboxSections, classifyInboxMission, countUnreadInboxMissions, listUnreadInboxCandidates } from "../src/inboxModel";
import { inboxConfig, InboxSettings, saveInboxConfig } from "../src/inboxSettings";
import { sideQuestionKey } from "../src/sideQuestionStorage";
import type { StreamItem } from "../src/transcriptModel";

const mission = (id: string, extra: Partial<Mission> = {}): Mission => ({
  id, title: id, project: "orb", status: "completed", history: [],
  updated_at: "2026-10-09T12:00:00Z", ...extra,
});
const projects = [{ slug: "orb", title: "Orb" }];
const question: StreamItem[] = [{
  kind: "tool", key: "q", callId: "q", name: "AskUserQuestion", done: false,
  args: { questions: [{ question: "Continue?", options: [{ label: "Yes" }] }] },
}];

describe("Inbox creation scope", () => {
  const autonomous = [
    mission("worker", { parent_mission_id: "human", status: "failed" }),
    mission("callback", { callback_parent_mission_id: "human", status: "awaiting_user" }),
    mission("dispatch", { tags: ["worker-dispatch:job"] }),
    // Production screenshot: controller origin survives without an origin session or parent.
    mission("0b033477", { origin: "hermes", origin_session_id: null, status: "interrupted" }),
    mission("legacy", { tags: ["origin:hermes-assistant"] }),
    mission("legacy-origin", { tags: ["origin:hermes"] }),
  ];

  it("hides automated roots and children before checking their pending interactions", () => {
    for (const row of autonomous) {
      expect(classifyInboxMission(row, { callId: "q", toolName: "question", kind: "question", remote: false, prompt: "Continue?", options: [] })).toBe("hidden");
    }
    const rows = [mission("human", { origin: "orb" }), ...autonomous];
    const sections = buildInboxSections(rows, projects, () => question);
    expect([...sections.needsYou, ...sections.ready].map((i) => i.id)).toEqual(["human"]);
    expect(listUnreadInboxCandidates(rows, projects, () => question).map((i) => i.id)).toEqual(["human"]);
    expect(countUnreadInboxMissions(rows, projects, () => question)).toBe(sections.unreadCount);
  });

  it("does not turn a read parent unread or urgent solely because a child failed", () => {
    const parent = mission("human", { first_viewed_at: "2026-10-09T13:00:00Z" });
    const child = mission("failed-child", { parent_mission_id: parent.id, status: "failed" });
    const sections = buildInboxSections([parent, child], projects);
    expect(sections.ready[0].childSummary?.failed).toBe(1);
    expect(sections.ready[0].unread).toBe(false);
    expect(sections.ready[0].attention).toBe(false);
    expect(countUnreadInboxMissions([parent, child], projects)).toBe(0);
  });

  it("restores autonomous updates and badge counts when opted in", () => {
    const scope = { includeAutonomous: true };
    const rows = [mission("human"), ...autonomous];
    const sections = buildInboxSections(rows, projects, () => question, undefined, Date.now(), undefined, scope);
    expect([...sections.needsYou, ...sections.ready]).toHaveLength(rows.length);
    expect(countUnreadInboxMissions(rows, projects, () => question, undefined, undefined, scope)).toBe(rows.length);
    expect(classifyInboxMission(mission("old", { tags: ["superseded"] }), undefined, scope)).toBe("hidden");
  });

  it("keeps a manual agent visible after an automatic watchdog message", () => {
    const row = mission("manual-with-watchdog", { history: [{ role: "user", content: "[worker-watchdog] Child is stalled" }] });
    expect(classifyInboxMission(row)).toBe("ready");
  });
});

describe("Inbox scope settings", () => {
  it("defaults to off, including saved settings from before this preference existed", () => {
    expect(inboxConfig().includeAutonomous).toBe(false);
    localStorage.setItem(sideQuestionKey("settings:inbox"), JSON.stringify({ aiSummary: false, model: "builtin/fast" }));
    expect(inboxConfig()).toEqual({ aiSummary: false, model: "builtin/fast", includeAutonomous: false });
  });

  it("persists the switch, can turn it off again, and preserves it when saving the model", () => {
    const view = render(() => <InboxSettings />);
    const toggle = screen.getByRole("switch", { name: "Include autonomous agents" });
    expect(toggle.getAttribute("aria-checked")).toBe("false");
    fireEvent.click(toggle);
    expect(inboxConfig().includeAutonomous).toBe(true);
    saveInboxConfig({ aiSummary: true, model: "builtin/fast" });
    expect(inboxConfig().includeAutonomous).toBe(true);
    view.unmount();
    render(() => <InboxSettings />);
    fireEvent.click(screen.getByRole("switch", { name: "Include autonomous agents" }));
    expect(inboxConfig().includeAutonomous).toBe(false);
  });
});
