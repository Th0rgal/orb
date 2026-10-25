import { render } from "@solidjs/testing-library";
import { describe, expect, it } from "vitest";
import { Transcript } from "../src/Transcript";
import { buildTranscript, type StreamItem } from "../src/transcriptModel";
import { spineAnswers } from "../src/missionCache";
import { storedToStream, type StreamEvent } from "../src/stream";

const start = "2026-10-25T10:00:00.000Z", end = "2026-10-25T10:03:00.000Z";
const user = (id: string, at = start): StreamEvent => ({ type: "user_message", data: { id, content: "Do it", at } });
const answers = (items: StreamItem[]) => items.filter((i): i is Extract<StreamItem, { kind: "text" }> => i.kind === "text");
const labels = (items: StreamItem[]) => [...render(() => <Transcript items={items} />).container.querySelectorAll(".st-text")].map(row => row.querySelector(".response-time time")?.getAttribute("datetime") ?? null);

describe("every finished answer carries a time", () => {
  it("remote OpenCode: the receipt stamps the native bubble even though close() forgets bubbles", () => {
    const items = buildTranscript([
      user("u1"),
      { type: "text_op", data: { bubble_id: "opencode:ses:msg:prt_b", ops: [{ type: "insert", pos: 0, text: "Done: fixed it." }, { type: "finalize" }] } },
      { type: "assistant_message", data: { content: "Done: fixed it.", at: end } },
    ]);
    expect(answers(items).at(-1)?.at).toBe(end);
    expect(labels(items).at(-1)).toBe(end);
  });
  it("Antigravity canonical rows keep their stored time", () => {
    const items = buildTranscript([user("u1"), { type: "assistant_message", data: { content: "Waiting for the job.", canonical: true, bubble_id: "antigravity:c:j:85", at: end } }]);
    expect(answers(items)[0].at).toBe(end);
  });
  it("goal turn that ends WAITING (partial) still dates its answer", () => {
    const items = buildTranscript([
      user("u1"),
      { type: "text_delta", data: { content: "Started the job; waiting." } },
      { type: "assistant_message", data: { content: "Started the job; waiting.", partial: true, at: end } },
    ]);
    expect(answers(items)[0].at).toBe(end);
    expect(labels(items)[0]).toBe(end);
  });
  it("history/spine-loaded turn: stored rows (only user + answer, no tools) carry their timestamps", () => {
    const row = (id: number, event_type: string, content: string, timestamp: string) => storedToStream({ id, sequence: id, event_type, content, timestamp, metadata: {} } as never)!;
    expect(row(1, "text_delta", "Hi", end).data.at).toBe(end);
    const spine = spineAnswers([row(1, "user_message", "Go", start), row(2, "assistant_message", "Narration", start), row(3, "assistant_message", "The answer.", end)]);
    const items = buildTranscript(spine);
    expect(labels(items).at(-1)).toBe(end);
  });
  it("narration-folded turn: an answer without its own time uses the turn's latest", () => {
    const items: StreamItem[] = [
      { kind: "user", key: "u", text: "Go", at: start },
      { kind: "text", key: "n", text: "Looking at the store.", live: false, at: end },
      { kind: "tool", key: "t", callId: "c", name: "bash", args: {}, result: "ok", done: true } as StreamItem,
      { kind: "text", key: "a", text: "The answer.", live: false },
    ];
    expect(labels(items).at(-1)).toBe(end);
  });
  it("falls back to the turn start when nothing else is known, and never times a live answer", () => {
    expect(labels([{ kind: "user", key: "u", text: "Go", at: start }, { kind: "text", key: "a", text: "Seeded.", live: false }])).toEqual([start]);
    expect(labels([{ kind: "user", key: "u", text: "Go", at: start }, { kind: "text", key: "a", text: "Streaming", live: true }])).toEqual([null]);
  });
});
