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
    // OpenCode supports cancellation; Claude and Codex only advertise three states.
    const allowed = name === "todowrite" ? ["pending", "in_progress", "completed", "cancelled"] : ["pending", "in_progress", "completed"];
    if (!allowed.includes(status)) return null;
    tasks.push({ text, status: status as TaskStatus });
  }
  return tasks;
}
export function latestChecklist(items: StreamItem[]): Checklist | null {
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "user" && !item.queued) return null;
    if (item.kind !== "tool") continue;
    const tasks = parseChecklist(item.name, item.args);
    if (tasks !== null) return { key: item.key, tasks };
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
  if (!args) return null;
  const oldStr = typeof args.oldString === "string" ? args.oldString : typeof args.old_string === "string" ? args.old_string : null;
  const newStr = typeof args.newString === "string" ? args.newString : typeof args.new_string === "string" ? args.new_string : null;
  if (oldStr !== null && newStr !== null) {
    const oldLines = oldStr ? oldStr.split("\n") : [];
    const newLines = newStr ? newStr.split("\n") : [];
    const oldSet = new Map<string, number>();
    for (const l of oldLines) oldSet.set(l, (oldSet.get(l) ?? 0) + 1);
    let common = 0;
    for (const l of newLines) {
      const c = oldSet.get(l) ?? 0;
      if (c > 0) { common++; oldSet.set(l, c - 1); }
    }
    return {
      additions: Math.max(0, newLines.length - common),
      deletions: Math.max(0, oldLines.length - common),
      file: fileTarget(tool) ?? undefined,
    };
  }
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
    case "bash": case "shell": case "shell_command": case "exec_command": case "run_terminal_command": case "terminal": case "run_command": return "command";
    case "edit": case "write": case "multiedit": case "apply_patch": case "write_file": case "edit_file": case "patch": case "replace_file_content": case "multi_replace_file_content": case "write_to_file": return "edit";
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
