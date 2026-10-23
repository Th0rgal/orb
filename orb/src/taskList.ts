import type { StreamItem } from "./transcriptModel";
import { orbTaskcardStep } from "./orbKernel";
import { normalizeTaskStatus, parseChecklist, toolArgs, toolName, type Checklist, type TaskItem, type TaskStatus } from "./workModel";

/**
 * One task list for every harness. Two families exist:
 * - snapshot tools rewrite the whole list each call: Claude Code `TodoWrite`,
 *   OpenCode `todowrite`, Codex `update_plan`, Grok `todo_write`, Vibe `todo`
 *   (`action: "write"`);
 * - incremental tools edit one task per call: Claude Code `TaskCreate` /
 *   `TaskUpdate`, which are folded into the same list.
 * Only these exact tools are read; no task-like text is guessed from results.
 */
export const SNAPSHOT_TASK_TOOLS = ["todowrite", "update_plan", "todo_write", "todo"];
export const INCREMENTAL_TASK_TOOLS = ["taskcreate", "taskupdate"];
export const isTaskTool = (name: string) => {
  const n = toolName(name);
  return SNAPSHOT_TASK_TOOLS.includes(n) || INCREMENTAL_TASK_TOOLS.includes(n);
};

/** Vocabulary drifts between harnesses (Codex app-server sends `inProgress`). */
export function taskStatus(raw: unknown): TaskStatus | null {
  return typeof raw === "string" ? normalizeTaskStatus(raw.trim().replace(/([a-z])([A-Z])/g, "$1_$2")) : null;
}

/** A full-list snapshot from one tool call, or null when the call is not one. */
export function parseTaskList(name: string, input: unknown): TaskItem[] | null {
  const exact = parseChecklist(name, input);
  if (exact) return exact;
  const n = toolName(name), args = toolArgs(input);
  if (!args || !SNAPSHOT_TASK_TOOLS.includes(n)) return null;
  // Vibe's `todo` also has a read action, which carries no new list.
  if (n === "todo" && args.action !== "write") return null;
  const list = n === "update_plan" ? args.plan : args.todos;
  if (!Array.isArray(list) || list.length > 500) return null;
  const tasks: TaskItem[] = [];
  for (const entry of list) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null;
    const row = entry as Record<string, unknown>;
    const text = row.content ?? row.step ?? row.description ?? row.title;
    const status = taskStatus(row.status);
    if (typeof text !== "string" || !text.trim() || !status) return null;
    tasks.push({ text, status });
  }
  return tasks;
}

/** `Task #3 created successfully: …` is the id Claude Code later updates. */
function createdTaskId(item: Extract<StreamItem, { kind: "tool" }>): string | null {
  const result = item.result;
  const text = typeof result === "string" ? result : toolArgs(result) ? JSON.stringify(result) : "";
  const fromText = /Task #?(\w+) created/i.exec(text)?.[1];
  if (fromText) return fromText;
  const obj = toolArgs(result), task = obj && toolArgs(obj.task);
  const id = task?.id ?? obj?.taskId ?? obj?.id;
  return typeof id === "string" || typeof id === "number" ? String(id) : null;
}

/** Fold Claude Code TaskCreate/TaskUpdate calls into an ordered list. Tasks are
 * session-scoped, so the fold reads the whole transcript. */
export function foldIncrementalTasks(items: StreamItem[]): TaskItem[] {
  const tasks = new Map<string, TaskItem>();
  let anonymous = 0;
  for (const item of items) {
    if (item.kind !== "tool") continue;
    const n = toolName(item.name), args = toolArgs(item.args);
    if (!args) continue;
    if (n === "taskcreate") {
      const text = args.subject ?? args.description;
      if (typeof text !== "string" || !text.trim()) continue;
      const id = createdTaskId(item) ?? `anon:${++anonymous}`;
      tasks.set(id, { text, status: taskStatus(args.status) ?? "pending" });
    } else if (n === "taskupdate") {
      const id = args.taskId ?? args.task_id ?? args.id;
      if (typeof id !== "string" && typeof id !== "number") continue;
      const key = String(id).replace(/^#/, "");
      if (args.status === "deleted") { tasks.delete(key); continue; }
      const current = tasks.get(key);
      const text = typeof args.subject === "string" && args.subject.trim() ? args.subject : current?.text;
      if (!text) continue; // An update for a task this transcript never showed.
      tasks.set(key, { text, status: taskStatus(args.status) ?? current?.status ?? "pending" });
    }
  }
  return [...tasks.values()];
}

/** The task list for the current turn: the newest snapshot, or the folded
 * incremental list when the newest task call is incremental. */
export function latestTaskList(items: StreamItem[]): Checklist | null {
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "user" && !item.queued) return null;
    if (item.kind !== "tool") continue;
    const n = toolName(item.name);
    if (INCREMENTAL_TASK_TOOLS.includes(n)) {
      const tasks = foldIncrementalTasks(items.slice(0, i + 1));
      return tasks.length ? { key: item.key, tasks } : null;
    }
    const tasks = parseTaskList(item.name, item.args);
    if (tasks !== null) return { key: item.key, tasks };
    // A finished list we cannot read is newer than any older one; showing the
    // older (usually all-pending) list would claim no progress.
    if (item.done && SNAPSHOT_TASK_TOOLS.includes(n) && n !== "todo") return null;
  }
  return null;
}

/** How the turn that followed a task list ended, read from the transcript:
 * "finished" when a final answer arrived after it and nothing failed,
 * "stopped" when an error/cancel row follows or no final answer exists. */
export type TurnOutcome = "finished" | "stopped";
export function turnOutcomeAfter(items: StreamItem[], key: string): TurnOutcome {
  const start = items.findIndex(i => i.key === key);
  if (start < 0) return "stopped";
  let answered = false;
  for (const item of items.slice(start + 1)) {
    if (item.kind === "error") return "stopped";
    if (item.kind === "text" && !item.live && item.text.trim()) answered = true;
  }
  return answered ? "finished" : "stopped";
}

export type ShownTask = { text: string; status: TaskStatus | "stale" };
export type TaskCardView = { tasks: ShownTask[]; label: string; state: "live" | "done" | "stale" | "stopped" };

/** How the Tasks card shows a plan. Once the turn is no longer running an
 * unfinished plan is not live progress: no item is "in progress" any more
 * (4ad4bc01 kept a spinning step 4/5 after its turn ended on a wake-up).
 * A turn that ended normally with open items only means the agent stopped
 * updating its list (ccd5a32b finished all phases after its last todowrite),
 * so it reads "not updated", never "Stopped"; open items become "stale"
 * rather than unchecked. "Stopped" is kept for failed or interrupted turns. */
export function taskCardView(tasks: TaskItem[], ended: boolean, outcome: TurnOutcome = "stopped"): TaskCardView {
  const done = tasks.filter(t => t.status === "completed").length;
  const finished = tasks.every(t => t.status === "completed" || t.status === "cancelled");
  const counted = `${done}/${tasks.length} completed`;
  const state = orbTaskcardStep(ended, finished, outcome === "finished");
  if (state === "live") return { tasks, label: counted, state: "live" };
  if (state === "done") return { tasks, label: counted, state: "done" };
  if (state === "stale") return {
    tasks: tasks.map(t => t.status === "in_progress" || t.status === "pending" ? { ...t, status: "stale" as const } : t),
    label: `Task list not updated · turn finished (${counted})`,
    state: "stale",
  };
  const stop = tasks.findIndex(t => t.status === "in_progress" || t.status === "pending");
  return {
    tasks: tasks.map(t => t.status === "in_progress" ? { ...t, status: "pending" as const } : t),
    label: `Stopped at step ${stop + 1}/${tasks.length}`,
    state: "stopped",
  };
}

const sameRows = (a: readonly ShownTask[], b: readonly ShownTask[]) =>
  a.length === b.length && a.every((t, i) => t.text === b[i].text && t.status === b[i].status);
/** Structural equality for memos: the transcript re-parses its task list on
 * every items update (each refresh, each token), and a fresh array of equal
 * rows would make the keyed card list recreate every row. */
export const sameChecklist = (a: Checklist | null, b: Checklist | null) =>
  a === b || (!!a && !!b && a.key === b.key && sameRows(a.tasks, b.tasks));
export const sameTaskCardView = (a: TaskCardView, b: TaskCardView) =>
  a.state === b.state && a.label === b.label && sameRows(a.tasks, b.tasks);
