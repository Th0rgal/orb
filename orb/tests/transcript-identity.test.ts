import { expect, test } from "vitest";
import { applyStreamEvent, buildTranscript } from "../src/transcriptModel";

test("an event that changes nothing keeps the transcript's identity", () => {
  const items = buildTranscript([{ type: "user_message", data: { id: "u1", content: "hi" } }]);
  const same = applyStreamEvent(items, { type: "mission_activity", data: { label: "Tool running…" } });
  expect(same).toBe(items);
  const changed = applyStreamEvent(same, { type: "text_delta", data: { content: "hello", mode: "delta" } });
  expect(changed).not.toBe(items);
  expect(changed.length).toBe(2);
});

test("appending text ops on a long reply stay cheap", () => {
  let items = buildTranscript([{ type: "user_message", data: { id: "u1", content: "hi" } }]);
  const started = performance.now();
  for (let i = 0; i < 4000; i++) {
    items = applyStreamEvent(items, { type: "text_op", data: { bubble_id: "b", ops: [{ type: "insert", pos: 999999, text: "word ".repeat(10) }] } });
  }
  expect(performance.now() - started).toBeLessThan(500);
  const bubble = items.at(-1);
  expect(bubble?.kind === "text" && bubble.text.length).toBe(4000 * 50);
  // Positions still count code points for an insert in the middle.
  items = applyStreamEvent(buildTranscript([]), { type: "text_op", data: { bubble_id: "c", ops: [{ type: "insert", pos: 0, text: "héllo" }, { type: "insert", pos: 2, text: "X" }] } });
  const middle = items.at(-1);
  expect(middle?.kind === "text" && middle.text).toBe("héXllo");
});
