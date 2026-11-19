import { describe, expect, it } from "vitest";
import fixtures from "../../shared/orb-spec/fixtures/remote-goal.json";
import { applyRemoteGoalEvent, remoteGoalEvent, remoteGoalPhase, remoteGoalStatusLabel, type RemoteGoalProjection } from "../src/remoteGoal";

describe("remote goal envelope v1", () => {
  it("uses the supported fixture schema", () => {
    expect(fixtures.schema_version).toBe(2);
  });
  for (const fixture of fixtures.cases) {
    it(fixture.name, () => {
      expect(remoteGoalEvent(fixture.event)).toEqual(fixture.expected);
    });
  }
  it("does not mutate the received metadata", () => {
    const data = Object.freeze({ status: "blocked", reason: "needs_input" });
    const result = remoteGoalEvent({ type: "goal_status", data });
    expect(result?.data).not.toBe(data);
    expect(result?.data).toEqual(data);
  });
  it("projects iteration, completion and Stop truthfully", () => {
    let state: RemoteGoalProjection = { phase: "active", objective: "Ship it", iteration: 0 };
    state = applyRemoteGoalEvent(state, { type: "goal_iteration", data: { status: "active", objective: "Ship it", iteration: 2, summary: "Progress" } });
    expect(state).toMatchObject({ phase: "active", iteration: 2, detail: "Progress" });
    state = applyRemoteGoalEvent(state, { type: "goal_status", data: { status: "complete" } });
    expect(state.phase).toBe("complete");
    state = applyRemoteGoalEvent(state, { type: "goal_status", data: { status: "active" } });
    expect(state.phase).toBe("complete");
    expect(remoteGoalStatusLabel({ phase: "active", objective: "Ship it", iteration: 2 })).toBe("Goal in progress · iteration 2");
  });
  for (const fixture of fixtures.projection_cases) {
    it(`projects ${fixture.name} from Core state`, () => {
      const phase = remoteGoalPhase(fixture.status, fixture.reason);
      expect(phase).toBe(fixture.phase);
      expect(remoteGoalStatusLabel({ phase, objective: "Ship it", iteration: fixture.iteration })).toBe(fixture.label);
    });
  }
});
