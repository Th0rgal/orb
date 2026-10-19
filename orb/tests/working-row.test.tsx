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
it("shows one Working row with the elapsed time when no live row is visible", () => {
  const done: StreamItem = { kind: "tool", key: "x", name: "Bash", args: {}, done: true } as unknown as StreamItem;
  expect(liveTail([user, done])).toBe(false);
  const { container } = render(() => <Transcript items={[user, done]} working />);
  const row = container.querySelectorAll(".st-working");
  expect(row).toHaveLength(1);
  expect(row[0].textContent).toMatch(/^Working1 min 0[0-9] s$/);
});
it("shows nothing once the turn is over", () => {
  const { container } = render(() => <Transcript items={[user]} />);
  expect(container.querySelector(".st-working")).toBeNull();
});
