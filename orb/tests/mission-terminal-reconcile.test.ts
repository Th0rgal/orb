import { describe, expect, it } from "vitest";
import fixture from "../../shared/orb-spec/fixtures/mission-terminal-reconcile.json";
import type { Mission } from "../src/api";
import { mergeIncomingMission } from "../src/mission/MissionView";
import { followupAfterTerminal, snapshotAdmitted } from "../src/missionSnapshot";
import { missionActivity } from "../src/missionStatus";
import { missionPhase } from "../src/missionLaunch";

const row = (fields: Record<string, unknown>): Mission => ({ id: "734c3bb7", title: null, history: [], created_at: "2026-11-13T11:00:00Z", ...fields }) as unknown as Mission;

describe("shared/orb-spec/fixtures/mission-terminal-reconcile.json snapshots", () => {
  it.each(fixture.snapshots)("$name", ({ prev, incoming, expected }) => {
    const before = row(prev), next = row(incoming);
    expect(snapshotAdmitted(before, next)).toBe(expected.admitted);
    const merged = mergeIncomingMission(before, next);
    expect(merged.status).toBe(expected.status);
    expect(merged.terminal_reason ?? null).toBe(expected.terminal_reason ?? null);
    expect(missionActivity(merged).working).toBe(expected.working);
  });
});

describe("list row vs detail snapshot ordering", () => {
  it("a list row carries state_revision and updated_at but no run_generation; a detail snapshot orders by it", () => {
    // A detail read carries run_generation; a list row does not.
    const detail = row({ status: "completed", terminal_reason: "completed", updated_at: "2026-11-13T12:10:00Z", run_generation: 3, state_revision: 9 });
    const listRow = row({ status: "active", updated_at: "2026-11-13T12:15:00Z", state_revision: 8 });
    expect(listRow.run_generation).toBeUndefined();
    expect(snapshotAdmitted(detail, listRow)).toBe(false);
    const merged = mergeIncomingMission(detail, listRow);
    expect(merged.status).toBe("completed");
    expect(missionActivity(merged).working).toBe(false);
  });
});

describe("shared/orb-spec/fixtures/mission-terminal-reconcile.json follow-ups", () => {
  it.each(fixture.followups)("$name", ({ draft, terminal_updated_at, delivered, expected }) => {
    expect(followupAfterTerminal(
      { content: draft.content, postedAt: Date.parse(draft.posted_at), acknowledged: draft.acknowledged },
      Date.parse(terminal_updated_at),
      delivered.map(entry => ({ content: entry.content, at: Date.parse(entry.at) })),
    )).toBe(expected);
  });
});

describe("734c3bb7 replay", () => {
  it("restart, completion from another session and a late snapshot leave no stale job or indicator", () => {
    let m = row({ status: "active", updated_at: "2026-11-13T11:48:00Z", run_generation: 3, state_revision: 5 });
    m = mergeIncomingMission(m, row({ status: "completed", terminal_reason: "completed", updated_at: "2026-11-13T12:10:00Z", run_generation: 3, state_revision: 9 }));
    m = mergeIncomingMission(m, row({ status: "active", updated_at: "2026-11-13T12:19:30Z", run_generation: 3, state_revision: 7 }));
    expect(m.status).toBe("completed");
    expect(m.terminal_reason).toBe("completed");
    expect(missionActivity(m)).toEqual({ working: false, reason: "idle" });
    expect(missionPhase(m, true)).toMatchObject({ label: "Completed", moving: false });
  });
});
