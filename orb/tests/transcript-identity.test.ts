import { expect, test } from "vitest";
import { applyStreamEvent, applyStreamEvents, buildTranscript } from "../src/transcriptModel";

test("an event that changes nothing keeps the transcript's identity", () => {
  const items = buildTranscript([{ type: "user_message", data: { id: "u1", content: "hi" } }]);
  const same = applyStreamEvent(items, { type: "mission_activity", data: { label: "Tool running…" } });
  expect(same).toBe(items);
  const changed = applyStreamEvent(same, { type: "text_delta", data: { content: "hello", mode: "delta" } });
  expect(changed).not.toBe(items);
  expect(changed.length).toBe(2);
});

test("cross-tab queued user_message edit updates text in place while preserving key, order, and metadata", () => {
  const initial = buildTranscript([
    { type: "user_message", eventId: "u1", sequence: 1, data: { id: "u1", content: "first" } },
    { type: "user_message", eventId: "q1", data: { id: "q1", content: "draft one", queued: true, receipt: true, attached: true, source: "remote-queue" } },
    { type: "user_message", eventId: "q2", data: { id: "q2", content: "draft two", queued: true, receipt: true } },
  ]);
  const edited = applyStreamEvent(initial, {
    type: "user_message",
    eventId: "q1",
    data: { id: "q1", content: "edited in tab A", queued: true, source: "remote-queue" },
  });
  expect(edited.map(i => i.key)).toEqual(["user:u1", "user:q1", "user:q2"]);
  expect(edited[1]).toMatchObject({
    kind: "user",
    key: "user:q1",
    messageId: "q1",
    text: "edited in tab A",
    queued: true,
    receipt: true,
    attached: true,
    source: "remote-queue",
  });
  expect(edited[2]).toBe(initial[2]);
  const unchanged = applyStreamEvent(edited, {
    type: "user_message",
    eventId: "q1",
    data: { id: "q1", content: "edited in tab A", queued: true, source: "remote-queue" },
  });
  expect(unchanged).toBe(edited);
  const resynced = applyStreamEvents(
    buildTranscript([
      { type: "user_message", eventId: "u1", sequence: 1, data: { id: "u1", content: "first" } },
      { type: "user_message", eventId: "q1", data: { id: "q1", content: "edited in tab A", queued: true } },
      { type: "user_message", eventId: "q2", data: { id: "q2", content: "draft two", queued: true } },
    ]),
    edited
      .filter((i): i is Extract<(typeof edited)[number], { kind: "user" }> => i.kind === "user" && Boolean(i.queued && i.messageId))
      .map(i => ({ type: "user_message", data: { id: i.messageId, content: i.text, queued: true, receipt: i.receipt, attached: i.attached } })),
  );
  expect(resynced.map(i => i.kind === "user" ? `${i.key}:${i.text}:${Boolean(i.queued)}` : i.kind)).toEqual([
    "user:u1:first:false",
    "user:q1:edited in tab A:true",
    "user:q2:draft two:true",
  ]);
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
