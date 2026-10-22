import { describe, it, expect } from "vitest";
import { spineAnswers } from "../src/missionCache";
import { buildTranscript, type StreamItem } from "../src/transcriptModel";
import type { StreamEvent } from "../src/stream";

let seq = 0;
const row = (type: string, data: Record<string, unknown>): StreamEvent => ({ type, data, sequence: ++seq });
const say = (text: string, bubble: string) => row("assistant_message", { content: text, canonical: true, bubble_id: bubble, success: true });

describe("conversational spine on first paint", () => {
  it("keeps each turn's answer and drops narration whose tools are not loaded yet", () => {
    seq = 0;
    // Replays prod mission 721edf55: a tool-heavy tail page (no user/assistant
    // rows) plus the spine before it, full of OpenCode text_op narration.
    const spine = [
      row("user_message", { id: "u1", content: "integrate the kernel" }),
      say("Let me check.", "opencode:s:p1"),
      row("assistant_message", { content: "Integrated.", success: true }),
      row("user_message", { id: "u2", content: "continue" }),
      say("WAIT A MINUTE! Why did ld keep it?", "opencode:s:p2"),
      say("HOLD ON! Look at nm.", "opencode:s:p3"),
      say("Aha! Look at that error.", "opencode:s:p4"),
    ];
    const tail = [
      row("tool_call", { tool_call_id: "t1", name: "bash", args: { command: "nm" } }),
      row("tool_result", { tool_call_id: "t1", name: "bash", result: "ok" }),
      row("tool_call", { tool_call_id: "t2", name: "bash", args: { command: "ld" } }),
    ];
    const items = buildTranscript([...spineAnswers(spine), ...tail]);
    const texts = items.filter((i): i is Extract<StreamItem, { kind: "text" }> => i.kind === "text").map(i => i.text);
    expect(texts).toEqual(["Integrated.", "Aha! Look at that error."]);
    expect(items.filter(i => i.kind === "user")).toHaveLength(2);
  });
  it("never drops a failure row", () => {
    seq = 0;
    const spine = [row("assistant_message", { content: "boom", success: false }), say("later", "b")];
    expect(spineAnswers(spine)).toHaveLength(2);
  });
});
