import { describe, expect, it } from "vitest";
import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import type { Mission } from "../src/api";
import { buildInboxSections, classifyInboxMission, countUnreadInboxMissions, listUnreadInboxCandidates } from "../src/inboxModel";
import {
  applySharedInboxPreferences,
  inboxConfig,
  InboxSettings,
  InboxSummariesSettings,
  saveInboxConfig,
} from "../src/inboxSettings";
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
    expect(inboxConfig().inboxEnabled).toBe(true);
    expect(inboxConfig().summaryMode).toBe("standard");
    localStorage.setItem(sideQuestionKey("settings:inbox"), JSON.stringify({ aiSummary: false, model: "builtin/fast" }));
    expect(inboxConfig()).toEqual({
      inboxEnabled: true,
      aiSummary: false,
      summaryMode: "standard",
      model: "builtin/fast",
      includeAutonomous: false,
    });
  });

  it("persists Enable Inbox, autonomous scope, and summary mode while preserving choices", () => {
    const view = render(() => <InboxSummariesSettings />);
    const enableToggle = screen.getByRole("switch", { name: "Enable Inbox" });
    const toggle = screen.getByRole("switch", { name: "Include autonomous agents" });
    const modePicker = screen.getByLabelText("Summary mode") as HTMLSelectElement;
    expect(enableToggle.getAttribute("aria-checked")).toBe("true");
    expect(toggle.getAttribute("aria-checked")).toBe("false");
    expect(modePicker.value).toBe("standard");
    fireEvent.click(toggle);
    fireEvent.change(modePicker, { target: { value: "eco" } });
    expect(inboxConfig().includeAutonomous).toBe(true);
    expect(inboxConfig().summaryMode).toBe("eco");
    saveInboxConfig({ aiSummary: true, model: "builtin/fast" });
    expect(inboxConfig().includeAutonomous).toBe(true);
    expect(inboxConfig().summaryMode).toBe("eco");
    fireEvent.click(enableToggle);
    expect(inboxConfig().inboxEnabled).toBe(false);
    expect(inboxConfig().summaryMode).toBe("eco");
    view.unmount();
    render(() => <InboxSummariesSettings />);
    fireEvent.click(screen.getByRole("switch", { name: "Enable Inbox" }));
    expect(inboxConfig().inboxEnabled).toBe(true);
    expect(inboxConfig().summaryMode).toBe("eco");
    fireEvent.click(screen.getByRole("switch", { name: "Include autonomous agents" }));
    expect(inboxConfig().includeAutonomous).toBe(false);
  });

  it("links Notifications to Agents → Inbox & summaries", () => {
    const opened: string[] = [];
    render(() => <InboxSettings onOpenPage={(id) => opened.push(id)} />);
    fireEvent.click(screen.getByRole("button", { name: "Configure" }));
    expect(opened).toEqual(["inbox-summaries"]);
  });
});

describe("AI summaries picker", () => {
  it("remembers a selected model and summary mode across Off, remount and re-enable", () => {
    saveInboxConfig({ inboxEnabled: true, aiSummary: true, summaryMode: "eco", model: "team/summary", includeAutonomous: true }, false);
    const view = render(() => <InboxSummariesSettings />);
    const picker = screen.getByLabelText("AI summaries");
    fireEvent.change(picker, { target: { value: "" } });
    expect(inboxConfig()).toEqual({
      inboxEnabled: true,
      aiSummary: false,
      summaryMode: "eco",
      model: "team/summary",
      includeAutonomous: true,
    });
    view.unmount();
    render(() => <InboxSummariesSettings />);
    const restored = screen.getByLabelText("AI summaries") as HTMLSelectElement;
    expect(restored.value).toBe("");
    fireEvent.change(restored, { target: { value: "team/summary" } });
    expect(inboxConfig()).toEqual({
      inboxEnabled: true,
      aiSummary: true,
      summaryMode: "eco",
      model: "team/summary",
      includeAutonomous: true,
    });
  });
  it("reflects shared preferences while mounted without overwriting them on Off", async () => {
    saveInboxConfig({ inboxEnabled: true, aiSummary: true, summaryMode: "standard", model: "builtin/smart" }, false);
    render(() => <InboxSummariesSettings />);
    applySharedInboxPreferences({ inboxEnabled: true, aiSummary: true, summaryMode: "on_open", model: "team/remote", includeAutonomous: true });
    const picker = screen.getByLabelText("AI summaries") as HTMLSelectElement;
    await waitFor(() => expect(picker.value).toBe("team/remote"));
    fireEvent.change(picker, { target: { value: "" } });
    expect(inboxConfig()).toEqual({
      inboxEnabled: true,
      aiSummary: false,
      summaryMode: "on_open",
      model: "team/remote",
      includeAutonomous: true,
    });
  });
  it("cancels custom edits without enabling summaries or replacing the saved model", () => {
    saveInboxConfig({ inboxEnabled: true, aiSummary: false, summaryMode: "standard", model: "builtin/fast" }, false);
    render(() => <InboxSummariesSettings />);
    fireEvent.change(screen.getByLabelText("AI summaries"), { target: { value: "__custom__" } });
    fireEvent.input(screen.getByLabelText("Model or chain ID"), { target: { value: "custom/new" } });
    fireEvent.click(screen.getByText("Cancel"));
    expect(screen.getByText("Discard unsaved changes?")).toBeTruthy();
    fireEvent.click(screen.getByText("Discard changes"));
    expect(inboxConfig().aiSummary).toBe(false);
    expect(inboxConfig().model).toBe("builtin/fast");
  });
});
