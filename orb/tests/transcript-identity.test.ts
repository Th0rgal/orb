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
