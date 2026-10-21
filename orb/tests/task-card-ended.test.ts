import { expect, test } from "vitest";
import { buildTranscript } from "../src/transcriptModel";
import { latestTaskList, taskCardView } from "../src/taskList";

const todo = (id: string, statuses: string[]) => ({ type: "tool_call", data: { tool_call_id: id, name: "todowrite", args: { todos: statuses.map((status, i) => ({ content: `step ${i + 1}`, status })) } } });

test("an ended turn shows where the plan stopped, with nothing in progress", () => {
  const tasks = [
    { text: "a", status: "completed" }, { text: "b", status: "completed" }, { text: "c", status: "completed" },
    { text: "d", status: "in_progress" }, { text: "e", status: "pending" },
  ] as never;
  const live = taskCardView(tasks, false);
  expect(live.label).toBe("3/5 completed");
  const ended = taskCardView(tasks, true);
  expect(ended.label).toBe("Stopped at step 4/5");
  expect(ended.tasks.some(t => t.status === "in_progress")).toBe(false);
  expect(taskCardView([{ text: "a", status: "completed" }] as never, true).label).toBe("1/1 completed");
});

test("each todowrite of a turn replaces the card's plan live", () => {
  const events = [{ type: "user_message", data: { id: "u", content: "go" } }, todo("prt_1:call_0", ["in_progress", "pending"])];
  expect(latestTaskList(buildTranscript(events))?.tasks.map(t => t.status)).toEqual(["in_progress", "pending"]);
  events.push(todo("prt_2:call_0", ["completed", "in_progress"]));
  expect(latestTaskList(buildTranscript(events))?.tasks.map(t => t.status)).toEqual(["completed", "in_progress"]);
  // Legacy ids that OpenCode reused across responses also advance the plan.
  events.push(todo("prt_2:call_0", ["completed", "completed"]));
  expect(latestTaskList(buildTranscript(events))?.tasks.map(t => t.status)).toEqual(["completed", "completed"]);
});
