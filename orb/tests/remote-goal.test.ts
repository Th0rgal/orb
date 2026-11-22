import { applyStreamEvent, buildTranscript, projectCompletedGoal, visibleTranscript } from "../src/transcriptModel";
import { confirmedGoalAnswer, confirmedGoalRecap } from "../src/remoteGoal";
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

describe("confirmed Goal transcript presentation", () => {
  const marker = "<!-- GOAL_COMPLETE -->";
  const raw = "11 + 8 = 19.\n\n19\n" + marker;
  const answer = { type: "assistant_message", data: { content: raw } };
  const complete = { type: "goal_status", data: { status: "complete", reason: "remote_goal_complete" } };

  it("replays the original final followed by the confirmed completion in history and live", () => {
    const initial = buildTranscript([answer]);
    const live = applyStreamEvent(initial, complete);
    expect(live).toEqual(buildTranscript([answer, complete]));
    expect(live[0]).toMatchObject({ text: "11 + 8 = 19.\n\n19", goalMarkedText: raw });
    expect(initial[0]).toMatchObject({ text: raw });
    expect(answer.data.content).toBe(raw);
    expect(projectCompletedGoal(initial)).toEqual(live);
    expect(projectCompletedGoal(live)).toBe(live);
    expect(applyStreamEvent(live, { type: "text_delta", data: { content: raw } })).toEqual(live);
  });

  it("scopes completion to the current answer and hides a marker-only bubble", () => {
    const user = { type: "user_message", data: { content: "Explain the marker" } };
    expect(buildTranscript([answer, user, complete])[0]).toMatchObject({ text: raw });
    expect(buildTranscript([answer, complete, user, answer]).at(-1)).toMatchObject({ text: raw });
    expect(buildTranscript([answer, { type: "goal_status", data: { status: "complete" } }])[0]).toMatchObject({ text: raw });
    expect(visibleTranscript(buildTranscript([{ type: "assistant_message", data: { content: marker } }, complete]))).toEqual([]);
  });

  it("keeps quoted, fenced, embedded, indented and nonterminal examples", () => {
    for (const text of ["> " + marker, "inline " + marker, "    " + marker, "`" + marker + "`", "~~~html\n" + marker,
      "````html\n```\n" + marker, marker + "\nmore"]) {
      expect(confirmedGoalAnswer(text)).toBeUndefined();
    }
    expect(confirmedGoalAnswer("~~~html\n" + marker + "\n~~~\r\nresult\r\n" + marker + "\r\n"))
      .toBe("~~~html\n" + marker + "\n~~~\r\nresult");
    expect(confirmedGoalRecap("A different quotation " + marker, raw)).toBe("A different quotation " + marker);
  });
});
