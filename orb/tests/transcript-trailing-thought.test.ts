import { expect, it } from "vitest";
import { applyStreamEvent, buildTranscript } from "../src/transcriptModel";
import type { StreamEvent } from "../src/stream";

const think = (content: string, done = true): StreamEvent => ({ type: "thinking", data: { content, done } });
const tool = (id: string): StreamEvent => ({ type: "tool_call", data: { tool_call_id: id, name: "run", args: {} } });
const shape = (items: ReturnType<typeof buildTranscript>) => items.map(i => i.kind === "tool" ? `tool:${i.callId}` : i.kind === "text" ? `text:${i.text}` : i.kind === "user" ? `user:${i.text}` : i.kind === "think" ? `think:${i.text}${i.done ? "" : "…"}` : i.kind);

it("drops Antigravity's replay of the last thought after the final answer (mission 3730b838 shape)", () => {
  const bubble = "antigravity:c:x:1545";
  const items = buildTranscript([
    { type: "user_message", data: { id: "u", content: "go" } },
    think("Checks passed."), tool("a"), think("Checks passed."),
    { type: "tool_result", data: { tool_call_id: "a", result: "ok" } },
    think("Meta-specs added."),
    { type: "assistant_message", data: { content: "Report.", canonical: true, bubble_id: bubble, revision: 32 } },
    think("Meta-specs added."),
    { type: "goal_status", data: { status: "complete" } },
    { type: "assistant_message", data: { content: "Report.", success: true } },
    { type: "mission_status_changed", data: { status: "completed" } },
  ]);
  expect(shape(items)).toEqual(["user:go", "think:Checks passed.", "tool:a", "think:Meta-specs added.", "text:Report."]);
});

it("moves a new trailing thought before the final answer once the turn ends", () => {
  const items = buildTranscript([
    { type: "user_message", data: { id: "u", content: "go" } },
    tool("a"),
    { type: "text_delta", data: { content: "Answer." } },
    think("Wrapping up", false),
    { type: "assistant_message", data: { content: "Answer.", success: true } },
  ]);
  expect(shape(items)).toEqual(["user:go", "tool:a", "think:Wrapping up", "text:Answer."]);
});

it("drops empty and closing reasoning, and nothing stays live after completion", () => {
  let items = buildTranscript([
    { type: "user_message", data: { id: "u", content: "go" } },
    think("", false), think("Working", false),
    { type: "assistant_message", data: { content: "Done.", success: true } },
    think("   "),
  ]);
  items = applyStreamEvent(items, { type: "mission_status_changed", data: { status: "completed" } });
  expect(shape(items)).toEqual(["user:go", "think:Working", "text:Done."]);
  const open = buildTranscript([{ type: "user_message", data: { id: "u", content: "go" } }, think("Live", false), think("", true)]);
  expect(shape(open)).toEqual(["user:go"]);
});

it("keeps a fresh thought after text while the turn is still running", () => {
  const items = buildTranscript([
    { type: "user_message", data: { id: "u", content: "go" } },
    { type: "text_delta", data: { content: "Step one." } },
    think("Next step", false),
  ]);
  expect(shape(items)).toEqual(["user:go", "text:Step one.", "think:Next step…"]);
});
