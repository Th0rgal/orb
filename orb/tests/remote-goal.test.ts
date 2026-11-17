import { describe, expect, it } from "vitest";
import fixtures from "../../shared/orb-spec/fixtures/remote-goal.json";
import { remoteGoalEvent } from "../src/remoteGoal";

describe("remote goal envelope v1", () => {
  it("uses the supported fixture schema", () => {
    expect(fixtures.schema_version).toBe(1);
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
});
