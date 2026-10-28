import { afterEach, expect, it } from "vitest";
import { cleanup, render } from "@solidjs/testing-library";
import { Transcript, liveTail } from "../src/Transcript";
import type { StreamItem } from "../src/transcriptModel";
afterEach(cleanup);
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
