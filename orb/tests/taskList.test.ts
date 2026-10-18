import { describe, it, expect } from "vitest";
import { foldIncrementalTasks, latestTaskList, parseTaskList, taskStatus } from "../src/taskList";
import { computeDiffStats, workKind } from "../src/workModel";
import { planSteps } from "../src/PlanProgress";
import { buildTranscript } from "../src/transcriptModel";
import type { StreamEvent } from "../src/stream";
import fixtures from "./fixtures/task-tools.json";

const call = (name: string, args: unknown, id = name): StreamEvent => ({ type: "tool_call", data: { tool_call_id: id, name, args } });
const result = (name: string, value: unknown, id = name): StreamEvent => ({ type: "tool_result", data: { tool_call_id: id, name, result: value } });

describe("normalized task list", () => {
  it.each(fixtures)("still reads the existing $harness shape", fixture => {
    expect(parseTaskList(fixture.name, fixture.args)?.length).toBeGreaterThan(0);
  });
  it("reads Grok todo_write, Vibe todo writes and camelCase Codex statuses", () => {
    expect(parseTaskList("todo_write", { todos: [{ id: "1", content: "Read code", status: "in_progress" }] })).toEqual([{ text: "Read code", status: "in_progress" }]);
    expect(parseTaskList("todo", { action: "write", todos: [{ id: "a", content: "Ship", status: "cancelled", priority: "low" }] })).toEqual([{ text: "Ship", status: "cancelled" }]);
    expect(parseTaskList("todo", { action: "read" })).toBeNull();
    expect(parseTaskList("update_plan", { plan: [{ step: "Check", status: "inProgress" }] })).toEqual([{ text: "Check", status: "in_progress" }]);
    expect(taskStatus("Not Started")).toBe("pending");
    expect(taskStatus("whatever")).toBeNull();
  });
  it("rejects malformed lists and unrelated tools", () => {
    expect(parseTaskList("todo_write", { todos: [{ content: "x", status: "nope" }] })).toBeNull();
    expect(parseTaskList("write", { todos: [{ content: "x", status: "pending" }] })).toBeNull();
    expect(parseTaskList("todo", { action: "write", todos: "broken" })).toBeNull();
  });
  it("folds Claude Code TaskCreate and TaskUpdate into one ordered list", () => {
    const items = buildTranscript([
      call("TaskCreate", { subject: "Inspect", description: "Look around", activeForm: "Inspecting" }, "c1"),
      result("TaskCreate", "Task #1 created successfully: Inspect", "c1"),
      call("TaskCreate", { subject: "Test" }, "c2"),
      result("TaskCreate", "Task #2 created successfully: Test", "c2"),
      call("TaskCreate", { subject: "Drop me" }, "c3"),
      result("TaskCreate", "Task #3 created successfully: Drop me", "c3"),
      call("TaskUpdate", { taskId: "1", status: "completed" }, "u1"),
      call("TaskUpdate", { taskId: "2", status: "in_progress", subject: "Run tests" }, "u2"),
      call("TaskUpdate", { taskId: "3", status: "deleted" }, "u3"),
      call("TaskUpdate", { taskId: "99", status: "completed" }, "u4"),
    ]);
    expect(foldIncrementalTasks(items)).toEqual([{ text: "Inspect", status: "completed" }, { text: "Run tests", status: "in_progress" }]);
    expect(latestTaskList(items)).toEqual({ key: "tool:u4", tasks: [{ text: "Inspect", status: "completed" }, { text: "Run tests", status: "in_progress" }] });
  });
  it("keeps Claude tasks created in an earlier turn when this turn updates them, and hides lists from earlier turns", () => {
    const first = [
      { type: "user_message", data: { id: "u1", content: "go" } },
      call("TaskCreate", { subject: "Inspect" }, "c1"), result("TaskCreate", "Task #1 created successfully: Inspect", "c1"),
    ] as StreamEvent[];
    const followUp = { type: "user_message", data: { id: "u2", content: "continue" } } as StreamEvent;
    expect(latestTaskList(buildTranscript([...first, followUp]))).toBeNull();
    expect(latestTaskList(buildTranscript([...first, followUp, call("TaskUpdate", { taskId: "1", status: "in_progress" }, "u")]))?.tasks).toEqual([{ text: "Inspect", status: "in_progress" }]);
  });
  it("lets the newest list win across tool families", () => {
    const items = buildTranscript([
      call("TaskCreate", { subject: "Old" }, "c1"), result("TaskCreate", "Task #1 created successfully: Old", "c1"),
      call("TodoWrite", fixtures[0].args, "t"),
    ]);
    expect(latestTaskList(items)?.key).toBe("tool:t");
  });
  it("feeds plan progress from incremental tasks too", () => {
    const items = buildTranscript([
      { type: "user_message", data: { id: "p", content: "/plan ship it" } } as StreamEvent,
      call("TaskCreate", { subject: "Ship" }, "c1"), result("TaskCreate", "Task #1 created successfully: Ship", "c1"),
      call("TaskUpdate", { taskId: "1", status: "completed" }, "u1"),
    ]);
    expect(planSteps(items, items[0].key)).toEqual([{ text: "Ship", status: "completed" }]);
  });
});

describe("normalized diffs and tool kinds", () => {
  const tool = (name: string, args: unknown, res?: unknown) => ({ kind: "tool" as const, key: "k", callId: "k", name, args, result: res, done: true });
  it("sums Claude Code MultiEdit pairs", () => {
    expect(computeDiffStats(tool("MultiEdit", { file_path: "a.ts", edits: [{ old_string: "a", new_string: "b\nc" }, { old_string: "x\ny", new_string: "" }] }))).toEqual({ additions: 2, deletions: 3, file: "a.ts" });
  });
  it("sums OpenCode metadata.files across a patch", () => {
    expect(computeDiffStats(tool("patch", { patchText: "…" }, { metadata: { files: [{ file: "a.ts", additions: 3, deletions: 1 }, { file: "b.ts", additions: 2, deletions: 0 }] } }))).toEqual({ additions: 5, deletions: 1, file: undefined });
    expect(computeDiffStats(tool("edit", { filePath: "a.ts" }, { metadata: { files: [{ file: "a.ts", additions: 1, deletions: 2 }] } }))).toEqual({ additions: 1, deletions: 2, file: "a.ts" });
  });
  it("classifies Grok, OpenCode and Claude edit and command tools", () => {
    expect(workKind("search_replace")).toBe("edit");
    expect(workKind("NotebookEdit")).toBe("edit");
    expect(workKind("execute")).toBe("command");
    expect(computeDiffStats(tool("search_replace", { file_path: "a.ts", old_string: "a", new_string: "b" }))).toEqual({ additions: 1, deletions: 1, file: "a.ts" });
  });
});
