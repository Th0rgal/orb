import { afterEach, expect, it } from "vitest";
import { cleanup, render } from "@solidjs/testing-library";
import { Transcript, liveTail } from "../src/Transcript";
import { TranscriptReducer, type StreamItem } from "../src/transcriptModel";
import { withInitialPrompt } from "../src/missionLaunch";
import { seenTurnStart } from "../src/TurnStatus";
import type { Mission } from "../src/api";
afterEach(() => { cleanup(); localStorage.clear(); });
const user: StreamItem = { kind: "user", key: "u", text: "Go", at: new Date(Date.now() - 65_000).toISOString() } as StreamItem;
it("uses the live row as the only indicator", () => {
  const thinking: StreamItem = { kind: "think", key: "t", text: "", done: false } as StreamItem;
  expect(liveTail([user, thinking])).toBe(true);
  const { container } = render(() => <Transcript items={[user, thinking]} working />);
  expect(container.querySelectorAll(".st-working")).toHaveLength(0);
});
it("uses the existing work fold while the current action is loading", () => {
  const done: StreamItem = { kind: "tool", key: "x", name: "Bash", args: {}, done: true } as unknown as StreamItem;
  expect(liveTail([user, done])).toBe(false);
  const { container } = render(() => <Transcript items={[user, done]} working />);
  expect(container.querySelectorAll(".st-working")).toHaveLength(0);
  expect(container.querySelectorAll(".st-work")).toHaveLength(1);
  expect(container.querySelector(".st-work-label")?.textContent).toContain("command");
});
it("shows nothing once the turn is over", () => {
  const { container } = render(() => <Transcript items={[user]} />);
  expect(container.querySelector(".st-working")).toBeNull();
});
it("keeps the Working row under text a harness left marked live (OpenCode)", () => {
  // OpenCode streamed "step 3 done" then ran a silent `sleep 25`: the bubble
  // stayed live=true while the turn had moved on.
  const text: StreamItem = { kind: "text", key: "s3", text: "step 3 done", live: true };
  expect(liveTail([user, text])).toBe(false);
  const { container } = render(() => <Transcript items={[user, text]} working />);
  expect(container.querySelectorAll(".st-working")).toHaveLength(1);
});
it("marks a message still being handed to the agent as sending", () => {
  const sent = { kind: "user", key: "user:m2", text: "Now this", messageId: "m2" } as StreamItem;
  const { container } = render(() => <Transcript items={[user, sent]} sending="m2" working workingLabel="Sending on Nippur…" />);
  const bubbles = container.querySelectorAll(".user");
  expect(bubbles[bubbles.length - 1].classList.contains("sending")).toBe(true);
  expect(bubbles[0].classList.contains("sending")).toBe(false);
  expect(container.querySelector(".st-working")?.textContent).toMatch(/^Sending on Nippur…/);
});
it("anchors initial mission prompt to mission.created_at and hides elapsed time on unhydrated history placeholders", () => {
  const twoMinAgo = new Date(Date.now() - 125_000).toISOString();
  const mission = { id: "m-init", status: "active", title: "Run", created_at: twoMinAgo, updated_at: twoMinAgo, history: [{ role: "user", content: "Start proof" }] } as Mission;
  const seeded = withInitialPrompt([], mission, undefined, true);
  const { container } = render(() => <Transcript items={seeded} working />);
  expect(container.querySelector(".st-working-time")?.textContent).toMatch(/^2 min 0[5-9] s$/);
  expect(seenTurnStart("initial:m-init")).toBeUndefined();

  cleanup();
  const multiTurnMission = {
    id: "m-hist",
    status: "active",
    title: "Multi",
    created_at: twoMinAgo,
    updated_at: twoMinAgo,
    history: [
      { role: "user", content: "Turn 1" },
      { role: "assistant", content: "Reply 1" },
      { role: "user", content: "Turn 2" },
    ],
  } as Mission;
  const histSeeded = withInitialPrompt([], multiTurnMission, undefined, true);
  const view = render(() => <Transcript items={histSeeded} working />);
  expect(view.container.querySelector(".st-working-time")).toBeNull();
  expect(seenTurnStart("history:m-hist:2")).toBeUndefined();
});
it("preserves server timestamps across deferred user messages and clears enqueue timestamps on delivery", () => {
  const reducer = new TranscriptReducer();
  reducer.apply({
    type: "user_message",
    sequence: 1,
    data: {
      content: "Combined",
      source: "scheduler",
      at: "2026-11-03T01:00:00Z",
      messages: [
        ["11111111-2222-4333-8444-555555555555", "Deferred one"],
        ["22222222-3333-4444-8555-666666666666", "Deferred two"],
      ],
    },
  });
  expect(reducer.items.map(i => i.kind === "user" ? i.at : undefined)).toEqual(["2026-11-03T01:00:00Z", "2026-11-03T01:00:00Z"]);

  const queuedReducer = new TranscriptReducer();
  queuedReducer.apply({
    type: "user_message",
    data: { id: "q1", content: "Follow up", queued: true, at: "2026-11-03T01:00:00Z" },
  });
  expect((queuedReducer.items[0] as Extract<StreamItem, { kind: "user" }>).at).toBeUndefined();
  queuedReducer.apply({
    type: "user_message",
    sequence: 5,
    data: { id: "q1", content: "Follow up", queued: false, at: "2026-11-03T01:03:00Z" },
  });
  expect((queuedReducer.items[0] as Extract<StreamItem, { kind: "user" }>).at).toBe("2026-11-03T01:03:00Z");
});
