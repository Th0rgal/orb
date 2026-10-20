import { expect, it } from "vitest";
import { TranscriptReducer, buildTranscript, applyStreamEvents } from "../src/transcriptModel";
import { heldAfterHistory, storedToStream, type StreamEvent } from "../src/stream";

// Live repro, mission c24318b8 (remote Claude Code, prod Core 1653f6d3): what
// the SSE stream sent across a Send now interrupt. Core's per-connection
// text_delta_latest buffer was only cleared by an assistant_message, which a
// cut remote turn never produced.
const STEPS = "step 1 done\nstep 2 done\nstep 3 done\nstep 4 done\nstep 5 done";
const op = (ops: unknown[]): StreamEvent => ({ type: "text_op", data: { bubble_id: "text_delta_latest", ops } });
const len = (s: string) => Array.from(s).length;
const texts = (items: { kind: string }[]) => items.filter(i => i.kind === "text").map(i => (i as { text: string }).text);
const user1: StreamEvent = { type: "user_message", eventId: "u1", sequence: 1, data: { id: "u1", content: "sleep 25 ten times" } };
const receipt: StreamEvent = { type: "user_message", data: { id: "u2", content: "retest queued", receipt: true } };
const interrupted: StreamEvent = { type: "mission_status_changed", data: { status: "interrupted" } };
const reply = 'You said "retest queued", so I\'ll carry on';

it("does not glue the next turn's reply to the cut turn's text (carried live buffer)", () => {
  const r = new TranscriptReducer();
  r.apply(user1);
  r.apply(op([{ type: "insert", pos: 0, text: "step 1 done" }]));
  r.apply(op([{ type: "replace", range: [0, 11], text: STEPS }]));
  r.apply(receipt);
  r.apply(interrupted);
  r.apply({ type: "user_message", eventId: "u2", data: { id: "u2", content: "retest queued" } });
  // Old Core: the buffer still held STEPS, so the reply came as one replace.
  r.apply(op([{ type: "replace", range: [0, len(STEPS)], text: STEPS + reply }]));
  r.apply(op([{ type: "replace", range: [0, len(STEPS + reply)], text: STEPS + reply + "…" }]));
  expect(texts(r.items)).toEqual([STEPS, reply + "…"]);
  expect(r.items.map(i => i.kind)).toEqual(["user", "text", "user", "text"]);
});

it("keeps a genuine reply that happens to start like the previous one", () => {
  const r = new TranscriptReducer();
  r.apply(user1);
  r.apply(op([{ type: "insert", pos: 0, text: "OK" }]));
  r.apply({ type: "user_message", eventId: "u2", data: { id: "u2", content: "again" } });
  // A fresh buffer (fixed Core) inserts at 0: never stripped.
  r.apply(op([{ type: "insert", pos: 0, text: "OK, done" }]));
  expect(texts(r.items)).toEqual(["OK", "OK, done"]);
});

it("starts a new reply bubble after a delivered user message even when Core reuses the text id", () => {
  const r = new TranscriptReducer();
  r.apply({ type: "user_message", data: { id: "u1", content: "go" } } as StreamEvent);
  r.apply({ type: "text_delta", eventId: "text_delta", sequence: 5, data: { content: "step 1 done", mode: "delta" } });
  r.apply({ type: "user_message", data: { id: "u2", content: "retest queued", receipt: true } });
  r.apply({ type: "text_delta", eventId: "text_delta", sequence: 9, data: { content: "You said retest", mode: "delta" } });
  expect(texts(r.items)).toEqual(["step 1 done", "You said retest"]);
});

it("the replay right after the interrupt shows the cut turn's text once", () => {
  // t≈0.3 s: the status change triggers a resync. History holds the stored
  // text_delta row (this turn's text) and the interrupt, not yet the Send now
  // message; the held live ops of the same turn used to render a second block.
  const history: StreamEvent[] = [
    user1,
    { type: "text_delta", eventId: "text_delta_latest", sequence: 20, data: { content: STEPS } },
    { type: "mission_status_changed", sequence: 21, data: { status: "interrupted" } },
  ];
  const live: StreamEvent[] = [
    op([{ type: "insert", pos: 0, text: "step 1 done" }]),
    op([{ type: "replace", range: [0, 11], text: STEPS }]),
    receipt,
  ];
  const items = applyStreamEvents(buildTranscript(history), heldAfterHistory(history, live));
  expect(texts(items)).toEqual([STEPS]);
  expect(items.map(i => i.kind)).toEqual(["user", "text", "user"]);
});

it("the persisted partial assistant_message finalizes the cut turn instead of adding a copy", () => {
  const partialRow = storedToStream({ id: 24, event_id: "p1", sequence: 24, event_type: "assistant_message", timestamp: "", content: STEPS, metadata: { success: true, completion_evidence: { classification_source: "partial_turn_interrupted" } } })!;
  expect(partialRow.data.partial).toBe(true);
  // Live: the receipt is already below the text when the partial arrives.
  const r = new TranscriptReducer();
  r.apply(user1);
  r.apply(op([{ type: "insert", pos: 0, text: STEPS }]));
  r.apply(receipt);
  r.apply(interrupted);
  r.apply({ ...partialRow, sequence: undefined, storedId: undefined });
  expect(texts(r.items)).toEqual([STEPS]);
  expect(r.items.map(i => i.kind)).toEqual(["user", "text", "user"]);
  expect((r.items[1] as { live: boolean }).live).toBe(false);
  // Reload from storage after the next turn overwrote the text_delta row.
  const stored = buildTranscript([
    user1, interrupted, partialRow,
    { type: "user_message", eventId: "u2", sequence: 26, data: { id: "u2", content: "retest queued" } },
    { type: "text_delta", eventId: "text_delta_latest", sequence: 37, data: { content: reply } },
  ]);
  expect(texts(stored)).toEqual([STEPS, reply]);
  expect(stored.map(i => i.kind)).toEqual(["user", "text", "user", "text"]);
  // Replaying the live copy after that history adds nothing.
  const again = applyStreamEvents(stored, heldAfterHistory([user1, partialRow], [op([{ type: "insert", pos: 0, text: STEPS }]), { ...partialRow, sequence: undefined, storedId: undefined }]));
  expect(texts(again)).toEqual([STEPS, reply]);
});

it("removing a queued row keeps the transcript live: the next send and reply still show", async () => {
  const { removeUsers, mapUsers } = await import("../src/transcriptModel");
  let items = buildTranscript([user1, { type: "user_message", data: { id: "q1", content: "queued", queued: true } }]);
  // Before: a plain filter dropped the reducer state, the next live event threw,
  // and a message sent while the turn ran was shown nowhere until a resync.
  items = removeUsers(items, item => !!item.queued && item.messageId === "q1");
  items = mapUsers(items, item => item);
  items = applyStreamEvents(items, [{ type: "user_message", eventId: "q2", data: { id: "q2", content: "sent while running", queued: true, receipt: true } }]);
  items = applyStreamEvents(items, [op([{ type: "insert", pos: 0, text: "still streaming" }])]);
  expect(items.map(i => i.kind === "user" ? `user:${i.messageId}:${!!i.queued}` : i.kind)).toEqual(["user:u1:false", "user:q2:true", "text"]);
});
