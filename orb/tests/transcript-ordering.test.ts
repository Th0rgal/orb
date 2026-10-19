import { expect, it } from "vitest";
import { applyStreamEvent, buildTranscript } from "../src/transcriptModel";
import type { StreamEvent } from "../src/stream";

const text = (bubble: string, content: string): StreamEvent => ({ type: "text_delta", data: { bubble_id: bubble, content } });
const tool = (id: string): StreamEvent => ({ type: "tool_call", data: { tool_call_id: id, name: "read", args: {} } });
const shape = (items: ReturnType<typeof buildTranscript>) => items.map(i => i.kind === "tool" ? `tool:${i.callId}` : i.kind === "text" ? `text:${i.text}` : i.kind === "user" ? `user:${i.text}` : i.kind);

it("places a late Antigravity step before the tool that followed it, within the current turn", () => {
  const items = buildTranscript([
    { type: "user_message", data: { id: "u1", content: "first" } },
    tool("c:5"),
    { type: "assistant_message", data: { content: "done" } },
    { type: "user_message", data: { id: "u2", content: "second" } },
    tool("c:3"),
    text("antigravity:c:x:2", "step two"),
    text("antigravity:c:x:1", "step one"),
  ]);
  // Both steps precede tool c:3 of this turn; tool c:5 of the earlier turn is never a boundary.
  expect(shape(items)).toEqual(["user:first", "tool:c:5", "text:done", "user:second", "text:step two", "text:step one", "tool:c:3"]);
});

it("recognizes the native receipt from bubbles in transcript order", () => {
  let items = buildTranscript([{ type: "user_message", data: { id: "u", content: "q" } }, tool("c:9")]);
  for (const ev of [text("antigravity:c:x:1", "Hello "), text("antigravity:c:x:2", "world")]) items = applyStreamEvent(items, ev);
  items = applyStreamEvent(items, { type: "assistant_message", data: { content: "Hello world" } });
  expect(shape(items)).toEqual(["user:q", "text:Hello ", "text:world", "tool:c:9"]);
});

it("moves a delivered queued message after the reply that arrived while it waited", () => {
  let items = buildTranscript([
    { type: "user_message", data: { id: "u1", content: "first" } },
    { type: "user_message", data: { id: "q", content: "later", queued: true } },
  ]);
  items = applyStreamEvent(items, text("text_delta_latest", "answer"));
  items = applyStreamEvent(items, { type: "assistant_message", data: { content: "answer" } });
  items = applyStreamEvent(items, { type: "user_message", data: { id: "q", content: "later" } });
  items = applyStreamEvent(items, { type: "mission_status_changed", data: { status: "failed", summary: "Remote run failed" } });
  expect(shape(items)).toEqual(["user:first", "text:answer", "user:later", "error"]);
});
