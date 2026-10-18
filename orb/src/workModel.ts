import type { StreamItem } from "./transcriptModel";
import type { LocalActivity } from "./localAgents";

type Tool = Extract<StreamItem, { kind: "tool" }>;
export type TaskStatus = "pending" | "in_progress" | "completed" | "cancelled";
export interface TaskItem { text: string; status: TaskStatus }
export interface Checklist { key: string; tasks: TaskItem[] }

export function toolName(name: string): string {
  return name.replace(/^functions\./, "").toLowerCase();
}
export function toolArgs(value: unknown): Record<string, unknown> | null {
  if (typeof value === "string") { try { value = JSON.parse(value); } catch { return null; } }
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

/** Exact harness adapters, not a search for task-like text in arbitrary results. */
export function parseChecklist(name: string, input: unknown): TaskItem[] | null {
  const normalized = toolName(name), args = toolArgs(input);
  if (!args || !["todowrite", "update_plan"].includes(normalized)) return null;
  const codex = normalized === "update_plan";
  const list = args[codex ? "plan" : "todos"];
  if (!Array.isArray(list) || list.length > 500) return null;
  const tasks: TaskItem[] = [];
  for (const entry of list) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null;
    const text = entry[codex ? "step" : "content"], status = entry.status;
    if (typeof text !== "string" || !text.trim() || typeof status !== "string") return null;
    // Harnesses drift in vocabulary (blocked, done, canceled…); one odd status must not hide the whole list.
    const mapped = normalizeTaskStatus(status);
    if (!mapped) return null;
    tasks.push({ text, status: mapped });
  }
  return tasks;
}
export function normalizeTaskStatus(raw: string): TaskStatus | null {
  const v = raw.trim().toLowerCase().replace(/[\s-]+/g, "_");
  if (["pending", "todo", "not_started", "blocked", "waiting"].includes(v)) return "pending";
  if (["in_progress", "active", "running", "doing", "started"].includes(v)) return "in_progress";
  if (["completed", "complete", "done", "finished", "succeeded"].includes(v)) return "completed";
  if (["cancelled", "canceled", "skipped", "abandoned"].includes(v)) return "cancelled";
  return null;
}
export function latestChecklist(items: StreamItem[]): Checklist | null {
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "user" && !item.queued) return null;
    if (item.kind !== "tool") continue;
    const tasks = parseChecklist(item.name, item.args);
    if (tasks !== null) return { key: item.key, tasks };
    // A finished checklist call we cannot read is newer than any older list: showing the
    // older (usually all-pending) one would claim no progress. Streaming partial args still fall through.
    if (item.done && ["todowrite", "update_plan"].includes(toolName(item.name))) return null;
  }
  return null;
}

/** Map native local activities (OpenCode, Claude Code, Codex, Antigravity) into
 * StreamItem entries so the live turn shares the exact same Checklist, tool cards,
 * diff badges, and WorkFold components as remote streams. */
export function localActivitiesToStreamItems(activities: LocalActivity[]): StreamItem[] {
  const out: StreamItem[] = [];
  for (const act of activities) {
    if (act.kind === "status" || act.id === "antigravity:status") continue;
    if (act.kind === "thinking") {
      if (act.detail?.trim()) {
        out.push({
          kind: "think",
          key: `local-think:${act.id}`,
          text: act.detail.trim(),
          done: act.done,
        });
      }
      continue;
    }
    const detailObj = toolArgs(act.detail);
    let name = act.label;
    let args: unknown = null;
    let result: unknown = undefined;
    if (detailObj) {
      if (typeof detailObj.name === "string" && detailObj.name.trim()) name = detailObj.name.trim();
      else if (typeof detailObj.toolName === "string" && detailObj.toolName.trim()) name = detailObj.toolName.trim();
      else if (typeof detailObj.tool === "string" && detailObj.tool.trim()) name = detailObj.tool.trim();
      args = detailObj.input ?? detailObj.rawInput ?? detailObj.arguments ?? detailObj.args ?? detailObj;
      result = detailObj.output ?? detailObj.rawOutput ?? detailObj.result ?? (detailObj.error ? { error: detailObj.error } : undefined);
      if (detailObj.metadata && typeof detailObj.metadata === "object" && args && typeof args === "object" && !Array.isArray(args)) {
        args = { ...(args as Record<string, unknown>), __metadata: detailObj.metadata };
      }
    } else if (act.detail) {
      if (act.kind === "command") args = { command: act.detail };
      else result = act.detail;
    }
    if (act.failed && result === undefined) {
      result = { error: act.detail || "Failed", status: "failed" };
    }
    out.push({
      kind: "tool",
      key: `local-tool:${act.id}`,
      callId: act.id,
      name,
      args,
      result,
      done: act.done,
    });
  }
  return out;
}

export interface DiffStats {
  additions: number;
  deletions: number;
  file?: string;
}

function lineDiff(oldStr: string, newStr: string) {
  const oldLines = oldStr ? oldStr.split("\n") : [], newLines = newStr ? newStr.split("\n") : [];
  const remaining = new Map<string, number>();
  for (const l of oldLines) remaining.set(l, (remaining.get(l) ?? 0) + 1);
  let common = 0;
  for (const l of newLines) { const c = remaining.get(l) ?? 0; if (c > 0) { common++; remaining.set(l, c - 1); } }
  return { additions: Math.max(0, newLines.length - common), deletions: Math.max(0, oldLines.length - common) };
}

export function computeDiffStats(tool: Tool): DiffStats | null {
  const args = toolArgs(tool.args);
  const res = toolArgs(tool.result);
  const meta = (args?.__metadata && typeof args.__metadata === "object" ? args.__metadata : res?.metadata && typeof res.metadata === "object" ? res.metadata : null) as Record<string, unknown> | null;
  const filediff = (meta?.filediff && typeof meta.filediff === "object" ? meta.filediff : res?.filediff && typeof res.filediff === "object" ? res.filediff : null) as Record<string, unknown> | null;
  if (filediff && (typeof filediff.additions === "number" || typeof filediff.deletions === "number")) {
    return {
      additions: typeof filediff.additions === "number" ? filediff.additions : 0,
      deletions: typeof filediff.deletions === "number" ? filediff.deletions : 0,
      file: typeof filediff.file === "string" ? filediff.file : fileTarget(tool) ?? undefined,
    };
  }
  // OpenCode's newer edit/patch metadata lists every changed file.
  const files = Array.isArray(meta?.files) ? meta.files : null;
  if (files?.length) {
    let additions = 0, deletions = 0, counted = false;
    for (const f of files) {
      const row = toolArgs(f);
      if (typeof row?.additions === "number") { additions += row.additions; counted = true; }
      if (typeof row?.deletions === "number") { deletions += row.deletions; counted = true; }
    }
    const only = files.length === 1 ? toolArgs(files[0]) : null;
    const file = typeof only?.file === "string" ? only.file : typeof only?.path === "string" ? only.path : fileTarget(tool) ?? undefined;
    if (counted) return { additions, deletions, file };
  }
  if (!args) return null;
  // Claude Code MultiEdit carries a list of old/new pairs for one file.
  if (Array.isArray(args.edits) && args.edits.length) {
    let additions = 0, deletions = 0, counted = false;
    for (const e of args.edits) {
      const pair = toolArgs(e);
      const o = pair?.old_string ?? pair?.oldString, n = pair?.new_string ?? pair?.newString;
      if (typeof o !== "string" || typeof n !== "string") continue;
      const d = lineDiff(o, n); additions += d.additions; deletions += d.deletions; counted = true;
    }
    if (counted) return { additions, deletions, file: fileTarget(tool) ?? undefined };
  }
  const oldStr = typeof args.oldString === "string" ? args.oldString : typeof args.old_string === "string" ? args.old_string : null;
  const newStr = typeof args.newString === "string" ? args.newString : typeof args.new_string === "string" ? args.new_string : null;
  if (oldStr !== null && newStr !== null) return { ...lineDiff(oldStr, newStr), file: fileTarget(tool) ?? undefined };
  const n = toolName(tool.name);
  if ((n === "write" || n === "write_file" || n === "write_to_file") && typeof args.content === "string" && args.content) {
    const lines = args.content.replace(/\n$/, "").split("\n").length;
    if (lines > 0) return { additions: lines, deletions: 0, file: fileTarget(tool) ?? undefined };
  }
  const patchText = typeof args.patch === "string" ? args.patch : typeof args.diff === "string" ? args.diff : typeof tool.args === "string" && tool.args.includes("*** Begin Patch") ? tool.args : null;
  if (patchText) {
    let additions = 0, deletions = 0;
    for (const line of patchText.split("\n")) {
      if (line.startsWith("+") && !line.startsWith("+++")) additions++;
      else if (line.startsWith("-") && !line.startsWith("---")) deletions++;
    }
    if (additions > 0 || deletions > 0) return { additions, deletions, file: fileTarget(tool) ?? undefined };
  }
  return null;
}

type Kind = "read" | "search" | "command" | "edit" | "other";
export function workKind(name: string): Kind {
  switch (toolName(name)) {
    case "read": case "read_file": case "readfile": case "workspace_read_file": case "view_file": case "view_file_outline": case "view_code_item": return "read";
    case "grep": case "glob": case "search": case "websearch": case "web_search": case "list_files": case "search_files": case "list": case "list_dir": case "find_by_name": case "grep_search": return "search";
    case "bash": case "shell": case "shell_command": case "exec_command": case "run_terminal_command": case "terminal": case "run_command": case "execute": return "command";
    case "edit": case "write": case "multiedit": case "apply_patch": case "write_file": case "edit_file": case "patch": case "replace_file_content": case "multi_replace_file_content": case "write_to_file": case "search_replace": case "notebookedit": return "edit";
    default: return "other";
  }
}
export const fileTarget = (tool: Tool): string | null => {
  const args = toolArgs(tool.args);
  if (!args) return null;
  for (const key of ["file_path", "filePath", "path", "file", "TargetFile", "AbsolutePath", "SearchPath", "DirectoryPath"]) {
    const value = args[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
};
export function workSummary(items: StreamItem[]): string {
  const groups: Record<Kind, Tool[]> = { read: [], search: [], command: [], edit: [], other: [] };
  for (const item of items) if (item.kind === "tool") groups[workKind(item.name)].push(item);
  const parts: string[] = [];
  const count = (n: number, single: string, plural = `${single}s`) => `${n} ${n === 1 ? single : plural}`;
  for (const kind of ["read", "search", "command", "edit", "other"] as const) {
    const tools = groups[kind]; if (!tools.length) continue;
    if (kind === "read" || kind === "edit") {
      const targets = tools.map(fileTarget);
      parts.push(targets.every((target): target is string => target !== null)
        ? `${kind === "read" ? "Read" : "Edited"} ${count(new Set(targets).size, "file")}`
        : count(tools.length, kind));
    } else parts.push(count(tools.length, kind === "other" ? "other tool" : kind, kind === "search" ? "searches" : undefined));
  }
  return parts.length ? parts.join(" · ") : "Thought";
}
