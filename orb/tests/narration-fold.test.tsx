import { describe, it, expect } from "vitest";
import { render } from "@solidjs/testing-library";
import { Transcript, buildTranscript } from "../src/Transcript";
import { narrationKeys, narrationLine } from "../src/workModel";
import { isOrchestrationTool } from "../src/orchestrationModel";
import type { StreamEvent } from "../src/stream";
import type { StreamItem } from "../src/transcriptModel";

const ev = (type: string, data: Record<string, unknown>): StreamEvent => ({ type, data });
const say = (id: string, text: string, done = true): StreamEvent[] => [
  ev("text_op", { bubble_id: id, ops: [{ type: "insert", pos: 0, text }, ...(done ? [{ type: "finalize" }] : [])] }),
];
const call = (id: string, name = "bash", done = true): StreamEvent[] => [
  ev("tool_call", { tool_call_id: id, name, args: { command: `run ${id}` } }),
  ...(done ? [ev("tool_result", { tool_call_id: id, name, result: "ok" })] : []),
];
const texts = (items: StreamItem[], keys: Set<string>) => items.filter(i => i.kind === "text" && keys.has(i.key)).map(i => (i as { text: string }).text);

describe("narration model", () => {
  it("folds text between tool calls and keeps the answer after the last tool", () => {
    const items = buildTranscript([
      ev("user_message", { content: "fix it", id: "u1" }),
      ...say("a", "Let me look."), ...call("1"),
      ...say("b", "WAIT A MINUTE! Why did that pass?"), ...call("2"),
      ...say("c", "Fixed: the guard was inverted."),
    ]);
    expect(texts(items, narrationKeys(items, isOrchestrationTool))).toEqual(["Let me look.", "WAIT A MINUTE! Why did that pass?"]);
  });
  it("never folds across a user message, nor next to an orchestration tool alone", () => {
    const items = buildTranscript([
      ...say("a", "Done."),
      ev("user_message", { content: "again", id: "u2" }), ...call("1"),
      ...say("b", "Delegating."), ...call("s", "start_mission"),
      ...say("c", "All done."),
    ]);
    expect(texts(items, narrationKeys(items, isOrchestrationTool))).toEqual([]);
  });
  it("never folds the producer's cumulative bubble, which holds the whole answer", () => {
    const items = buildTranscript([
      ev("user_message", { content: "fix it", id: "u1" }),
      ev("text_delta", { content: "Inspect file." }), ...call("1"),
      ev("assistant_message", { content: "Inspect file. Done.", id: "a1" }),
    ]);
    expect(narrationKeys(items, isOrchestrationTool).size).toBe(0);
  });
  it("clamps narration to one plain line", () => {
    expect(narrationLine("**HOLD ON!**  Look at\n`nm` output:\n```\nU x\n```")).toBe("HOLD ON! Look at nm output:");
  });
});

describe("narration fold", () => {
  it("renders only the answer as top-level text and keeps narration inside the work fold", () => {
    const items = buildTranscript([
      ev("user_message", { content: "fix it", id: "u1" }),
      ...say("a", "HOLD ON! Look at the symbol table."), ...call("1"),
      ...say("b", "WAIT A MINUTE! Why did ld keep it?"), ...call("2"),
      ...say("c", "The kernel now links."),
    ]);
    const { container } = render(() => <Transcript items={items} />);
    const top = [...container.querySelectorAll(".st-text")].map(n => n.textContent);
    expect(top).toHaveLength(1);
    expect(top[0]).toContain("The kernel now links.");
    expect(container.querySelectorAll(".st-work")).toHaveLength(1);
    expect(container.textContent).not.toContain("WAIT A MINUTE");
    container.querySelector<HTMLButtonElement>(".st-work-head")!.click();
    expect([...container.querySelectorAll(".st-work-note")].map(n => n.textContent?.trim())).toEqual(["HOLD ON! Look at the symbol table.", "WAIT A MINUTE! Why did ld keep it?"]);
  });
  it("shows the latest narration as one line while the turn is still working", () => {
    const items = buildTranscript([
      ev("user_message", { content: "fix it", id: "u1" }),
      ...call("1"), ...say("a", "First idea."), ...call("2"),
      ...say("b", "**Aha!** Look at that error."), ...call("3", "bash", false),
    ]);
    const { container } = render(() => <Transcript items={items} working />);
    expect(container.querySelectorAll(".st-text")).toHaveLength(0);
    const note = container.querySelectorAll(".st-work-live-note");
    expect(note).toHaveLength(1);
    expect(note[0].textContent).toBe("Aha! Look at that error.");
  });
});
