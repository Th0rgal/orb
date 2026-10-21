import { expect, test } from "vitest";
import { buildTranscript } from "../src/transcriptModel";

test("legacy OpenCode history that reused call_0 keeps one row per call", () => {
  const items = buildTranscript([
    { type: "user_message", data: { id: "u1", content: "go" } },
    { type: "tool_call", data: { tool_call_id: "call_0", name: "read", args: { filePath: "a" } } },
    { type: "tool_result", data: { tool_call_id: "call_0", name: "read", result: "A" } },
    { type: "tool_call", data: { tool_call_id: "call_0", name: "bash", args: { command: "ls" } } },
    { type: "tool_result", data: { tool_call_id: "call_0", name: "bash", result: "B" } },
  ]);
  const tools = items.filter(i => i.kind === "tool");
  expect(tools.map(t => t.kind === "tool" && t.name)).toEqual(["read", "bash"]);
  expect(tools.map(t => t.kind === "tool" && t.result)).toEqual(["A", "B"]);
  expect(new Set(tools.map(t => t.key)).size).toBe(2);
});

test("a re-emitted finished call with the same arguments stays one row", () => {
  const items = buildTranscript([
    { type: "user_message", data: { id: "u1", content: "go" } },
    { type: "tool_call", data: { tool_call_id: "s:1", name: "read", args: { filePath: "a" } } },
    { type: "tool_result", data: { tool_call_id: "s:1", name: "read", result: "A" } },
    { type: "tool_call", data: { tool_call_id: "s:1", name: "read", args: { filePath: "a" } } },
  ]);
  expect(items.filter(i => i.kind === "tool").length).toBe(1);
});

test("OpenCode narration bubbles and the final answer are not shown twice", () => {
  const items = buildTranscript([
    { type: "user_message", data: { id: "u1", content: "go" } },
    { type: "text_op", data: { bubble_id: "opencode:s:p1", ops: [{ type: "snapshot", text: "Reading files", revision: 1 }, { type: "finalize" }] } },
    { type: "tool_call", data: { tool_call_id: "p2:call_0", name: "read", args: {} } },
    { type: "tool_result", data: { tool_call_id: "p2:call_0", name: "read", result: "x" } },
    { type: "assistant_message", data: { content: "Reading files", success: true } },
  ]);
  expect(items.filter(i => i.kind === "text").map(i => i.kind === "text" && i.text)).toEqual(["Reading files"]);
});
