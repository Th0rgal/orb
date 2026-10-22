import { expect, test } from "vitest";
import fixture from "./fixtures/stale-tasks-ccd5a32b.json";
import { buildTranscript } from "../src/transcriptModel";
import { latestTaskList, taskCardView, turnOutcomeAfter } from "../src/taskList";

const events = fixture.events as never[];

test("ccd5a32b: a turn that finished after its last todowrite reads as not updated, not stopped", () => {
  const items = buildTranscript(events);
  const list = latestTaskList(items)!;
  expect(list.tasks.map(t => t.status)).toEqual(["completed", "completed", "in_progress", "pending"]);
  expect(turnOutcomeAfter(items, list.key)).toBe("finished");
  const view = taskCardView(list.tasks, true, turnOutcomeAfter(items, list.key));
  expect(view.state).toBe("stale");
  expect(view.label).toBe("Task list not updated · turn finished (2/4 completed)");
  expect(view.label).not.toMatch(/Stopped/);
  expect(view.tasks.map(t => t.status)).toEqual(["completed", "completed", "stale", "stale"]);
});

test("ccd5a32b interrupted before the final answer stays Stopped", () => {
  const cut = events.slice(0, -1); // no final assistant message
  const items = buildTranscript(cut);
  const list = latestTaskList(items)!;
  expect(turnOutcomeAfter(items, list.key)).toBe("stopped");
  expect(taskCardView(list.tasks, true, "stopped").label).toBe("Stopped at step 3/4");
  const failed = buildTranscript([...cut, { type: "assistant_message", data: { content: "Interrupted", success: false } }] as never[]);
  expect(turnOutcomeAfter(failed, latestTaskList(failed)!.key)).toBe("stopped");
});

test("all complete is done, and a running turn is live", () => {
  const all = [{ text: "a", status: "completed" }, { text: "b", status: "cancelled" }] as never;
  expect(taskCardView(all, true, "finished")).toMatchObject({ state: "done", label: "1/2 completed" });
  const open = [{ text: "a", status: "in_progress" }] as never;
  expect(taskCardView(open, false, "finished")).toMatchObject({ state: "live", label: "0/1 completed" });
});
