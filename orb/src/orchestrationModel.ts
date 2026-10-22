import { createContext } from "solid-js";
import type { StreamItem } from "./transcriptModel";
import { toolArgs, toolName } from "./workModel";

/** One shared model for "this tool call started another agent" and "this tool
 * call created or destroyed a machine", whichever harness made the call and
 * however its MCP client prefixed the tool name (`sandboxed_start_mission`,
 * `mcp__sandboxed__start_mission`, `mcp_sandboxed_assistant_start_mission`,
 * `sandboxed.start_mission`…), and wherever the child ends up running. */

type Tool = Extract<StreamItem, { kind: "tool" }>;
export type OrchestrationKind = "subagent" | "machine-spawn" | "machine-destroy";
export type SubagentStatus = "starting" | "queued" | "running" | "done" | "failed" | "cancelled";

export interface SubagentRef {
  key: string;
  /** Native harness subagent (Task/Agent tool) vs a mission started through the orchestration API. */
  native: boolean;
  title: string;
  backend?: string;
  model?: string;
  /** Remote node the child was placed on (`managed-mm4b8tgs9y`, `ashur`…). */
  nodeId?: string;
  actionId?: string;
  missionId?: string;
  status: SubagentStatus;
  error?: string;
  summary?: string;
}

export interface MachineRef {
  key: string;
  action: "spawn" | "destroy";
  machineId?: string;
  nodeId?: string;
  name?: string;
  size?: string;
  state: "requested" | "provisioning" | "online" | "destroyed" | "failed";
  costUsd?: number;
  usdPerHour?: number;
  error?: string;
}

const NATIVE_SUBAGENT = new Set(["task", "agent", "delegate_task", "subagent", "spawn_subagent"]);

/** Bare operation name with harness/MCP-server prefixes removed. */
export function orchestrationOp(name: string): string {
  let n = toolName(name);
  if (n.startsWith("mcp__") && n.lastIndexOf("__") > 3) n = n.slice(n.lastIndexOf("__") + 2);
  n = n.slice(n.lastIndexOf(".") + 1);
  n = n.slice(n.lastIndexOf(":") + 1);
  return n.replace(/^(?:mcp_)?(?:sandboxed|orchestrator|paloma)(?:[_-](?:sh|assistant|orchestrator))*[_-]/, "");
}

export function orchestrationKind(name: string): OrchestrationKind | null {
  const op = orchestrationOp(name);
  if (op === "start_mission" || op === "create_mission" || op === "spawn_worker") return "subagent";
  if (op === "spawn_managed_machine") return "machine-spawn";
  if (op === "destroy_managed_machine") return "machine-destroy";
  return null;
}

export const isNativeSubagentTool = (name: string) => NATIVE_SUBAGENT.has(toolName(name));
export const isSubagentTool = (name: string) => isNativeSubagentTool(name) || orchestrationKind(name) === "subagent";

/** Lifted out of the "Worked" fold: these are what the run is about, not plumbing. */
export const isOrchestrationTool = (name: string) => orchestrationKind(name) !== null;

function parseJson(text: string): unknown {
  const t = text.trim();
  if (!t.startsWith("{") && !t.startsWith("[")) return text;
  try { return JSON.parse(t); } catch { return text; }
}

/** The JSON object the tool actually returned, through each harness's envelope:
 * OpenCode `{output:"<json>", error}`, MCP `{content:[{text}]}`/`structuredContent`, raw strings. */
export function toolPayload(result: unknown): { value: Record<string, unknown> | null; error?: string } {
  let r: unknown = typeof result === "string" ? parseJson(result) : result;
  for (let depth = 0; depth < 4; depth++) {
    const o = toolArgs(r);
    if (!o) return { value: null };
    if (o.structuredContent && typeof o.structuredContent === "object") { r = o.structuredContent; continue; }
    if (Array.isArray(o.content) && o.content.every(c => c && typeof c === "object")) {
      const text = o.content.map(c => typeof (c as { text?: unknown }).text === "string" ? (c as { text: string }).text : "").join("");
      if (text) { r = parseJson(text); if (o.isError === true || o.is_error === true) return { value: toolArgs(r), error: errorText(r) }; continue; }
    }
    if (typeof o.error === "string" && o.error.trim() && o.output == null) {
      const inner = parseJson(o.error);
      return { value: toolArgs(inner), error: errorText(inner) };
    }
    if (typeof o.output === "string" && ("name" in o || "error" in o || "rawInput" in o)) { r = parseJson(o.output); continue; }
    return { value: o };
  }
  return { value: toolArgs(r) };
}

function errorText(v: unknown): string {
  if (typeof v === "string") return v;
  const o = toolArgs(v);
  if (!o) return "Failed";
  const e = toolArgs(o.error) ?? o;
  return typeof e.message === "string" ? e.message : typeof o.error === "string" ? o.error : "Failed";
}

const s = (v: unknown) => typeof v === "string" && v.trim() ? v.trim() : undefined;
const n = (v: unknown) => typeof v === "number" && Number.isFinite(v) ? v : undefined;

function missionStatus(m: Record<string, unknown>): SubagentStatus | undefined {
  const raw = (s(m.status) ?? s(toolArgs(m.execution)?.state) ?? "").toLowerCase();
  if (!raw) return undefined;
  if (/^(completed|complete|done|succeeded|finished)$/.test(raw)) return "done";
  if (/fail|error|blocked|not_feasible|interrupted/.test(raw)) return "failed";
  if (/cancel/.test(raw)) return "cancelled";
  if (/queued|pending|admission|dispatching/.test(raw)) return "queued";
  return "running";
}

function firstLine(text: string, max = 280): string {
  // A one-line preview, not a Markdown renderer: drop emphasis, code ticks and list bullets.
  const t = text.replace(/\*\*|__|`/g, "").replace(/^\s*[-*]\s+/gm, "").replace(/\s+/g, " ").trim();
  return t.length > max ? `${t.slice(0, max)}…` : t;
}

/** Facts later calls in the same transcript reveal about an action or mission
 * (get_action, get_mission, get_mission_health…), keyed by id. */
export interface FollowUps {
  actions: Map<string, { value: Record<string, unknown> | null; error?: string; state?: string }>;
  missions: Map<string, Record<string, unknown>>;
  machines: Map<string, Record<string, unknown>>;
}

export function collectFollowUps(items: readonly StreamItem[]): FollowUps {
  const out: FollowUps = { actions: new Map(), missions: new Map(), machines: new Map() };
  const noteMachine = (m: Record<string, unknown> | null) => {
    if (!m) return;
    const id = s(m.id), node = s(m.node_id);
    if (!id && !node) return;
    const prev = (id && out.machines.get(id)) || (node && out.machines.get(node)) || {};
    const next = { ...prev, ...m };
    if (id) out.machines.set(id, next);
    if (node) out.machines.set(node, next);
  };
  const noteMission = (m: Record<string, unknown> | null) => {
    const id = m && (s(m.id) ?? s(m.mission_id));
    if (m && id && /^[0-9a-f-]{36}$/i.test(id)) out.missions.set(id, { ...out.missions.get(id), ...m });
  };
  for (const item of items) {
    if (item.kind !== "tool" || !item.done) continue;
    const op = orchestrationOp(item.name);
    const { value, error } = toolPayload(item.result);
    if (op === "get_action") {
      const id = s(toolArgs(item.args)?.action_id) ?? s(value?.action_id);
      if (!id) continue;
      const res = toolArgs(value?.result);
      out.actions.set(id, { value: res, error: error ?? (value?.error ? errorText(value) : undefined), state: s(value?.state) });
      noteMission(toolArgs(res?.mission));
      noteMachine(toolArgs(res?.machine) ?? (s(res?.node_id) && s(res?.state) ? res : null));
    } else if (op === "get_mission" || op === "get_mission_health" || op === "get_mission_status") {
      if (value) noteMission({ ...value, id: s(value.mission_id) ?? s(value.id) ?? s(toolArgs(item.args)?.mission_id) });
    } else if (op === "list_managed_machines" && value && Array.isArray(value.machines)) {
      for (const m of value.machines) noteMachine(toolArgs(m));
    }
  }
  return out;
}

/** Live mission rows the app already has (the sidebar list), by id. */
export type MissionLookup = (id: string) => { status?: string; title?: string | null; backend?: string; model_override?: string | null } | undefined;
export const MissionLookupContext = createContext<MissionLookup>(() => undefined);

export function subagentRef(tool: Tool, follow: FollowUps, lookup: MissionLookup = () => undefined): SubagentRef | null {
  const native = isNativeSubagentTool(tool.name);
  if (!native && orchestrationKind(tool.name) !== "subagent") return null;
  const a = toolArgs(tool.args) ?? {};
  const ref: SubagentRef = {
    key: tool.key, native,
    title: s(a.title) ?? s(a.description) ?? firstLine(s(a.prompt) ?? "Subagent", 90),
    backend: s(a.backend) ?? s(a.subagent_type) ?? s(a.agent),
    model: s(a.model_override) ?? s(a.model),
    nodeId: s(a.remote_node_id) ?? s(a.node_id) ?? s(a.machine),
    status: tool.done ? "queued" : "starting",
  };
  if (native) {
    ref.backend = s(a.subagent_type) ?? s(a.agent);
    if (tool.done) {
      const { value, error } = toolPayload(tool.result);
      ref.status = error || value?.is_error === true || value?.status === "failed" ? "failed" : "done";
      ref.error = error;
      const text = typeof tool.result === "string" ? tool.result : s(value?.output) ?? s(value?.result);
      if (text && ref.status === "done") ref.summary = firstLine(text);
    } else ref.status = "running";
    return ref;
  }
  if (!tool.done) return ref;
  const { value, error } = toolPayload(tool.result);
  if (error || value?.accepted === "no") { ref.status = "failed"; ref.error = error ?? errorText(value); return ref; }
  ref.actionId = s(value?.action_id);
  const direct = toolArgs(value?.mission) ?? (s(value?.mission_id) || s(value?.id) ? value : null);
  let mission = direct && (s(direct.mission_id) ?? s(direct.id)) ? direct : null;
  if (ref.actionId) {
    const act = follow.actions.get(ref.actionId);
    if (act?.error) { ref.status = "failed"; ref.error = act.error.replace(/^Outcome unconfirmed; inspect before retrying\.\s*/, ""); }
    const m = toolArgs(act?.value?.mission);
    if (m) mission = m;
  }
  const missionId = mission ? s(mission.mission_id) ?? s(mission.id) : undefined;
  if (missionId) {
    ref.missionId = missionId;
    const facts = { ...mission, ...follow.missions.get(missionId) };
    ref.title = s(facts.title) ?? ref.title;
    ref.backend = s(facts.backend) ?? ref.backend;
    ref.model = s(facts.model_override) ?? ref.model;
    const scope = s(toolArgs(facts.execution)?.scope_unit);
    if (!ref.nodeId && scope?.startsWith("remote-node:")) ref.nodeId = scope.slice("remote-node:".length);
    if (ref.status !== "failed") ref.status = missionStatus(facts) ?? "running";
    const last = s(facts.last_assistant_message);
    if (last) ref.summary = firstLine(last);
    const live = lookup(missionId);
    if (live) {
      ref.title = s(live.title) ?? ref.title;
      ref.backend = s(live.backend) ?? ref.backend;
      ref.model = s(live.model_override) ?? ref.model;
      ref.status = missionStatus({ status: live.status }) ?? ref.status;
    }
    if (ref.status !== "done") ref.summary = ref.status === "running" ? ref.summary : undefined;
  }
  return ref;
}

export function machineRef(tool: Tool, follow: FollowUps): MachineRef | null {
  const kind = orchestrationKind(tool.name);
  if (kind !== "machine-spawn" && kind !== "machine-destroy") return null;
  const a = toolArgs(tool.args) ?? {};
  const ref: MachineRef = { key: tool.key, action: kind === "machine-spawn" ? "spawn" : "destroy", machineId: s(a.machine_id), size: s(a.size), state: "requested" };
  if (!tool.done) return ref;
  const { value, error } = toolPayload(tool.result);
  if (error || value?.accepted === "no") return { ...ref, state: "failed", error: error ?? errorText(value) };
  let machine = toolArgs(value?.machine) ?? (s(value?.node_id) && s(value?.state) ? value : null);
  const actionId = s(value?.action_id);
  const act = actionId ? follow.actions.get(actionId) : undefined;
  if (act?.error) return { ...ref, state: "failed", error: act.error };
  if (act?.value) machine = toolArgs(act.value.machine) ?? (s(act.value.node_id) || s(act.value.id) ? act.value : machine);
  if (machine) {
    const later = follow.machines.get(s(machine.id) ?? s(machine.node_id) ?? "");
    // A spawn card reflects the machine's whole life: Online, then Destroyed once the same transcript destroys it.
    if (later) machine = { ...machine, ...later };
  } else if (ref.machineId) machine = follow.machines.get(ref.machineId) ?? null;
  if (machine) {
    ref.machineId = s(machine.id) ?? ref.machineId;
    ref.nodeId = s(machine.node_id);
    ref.name = s(machine.name) ?? s(machine.label) ?? s(machine.display_name);
    ref.size = s(machine.size) ?? ref.size;
    ref.costUsd = n(machine.cost_usd);
    ref.usdPerHour = n(machine.usd_per_hour);
    const st = (s(machine.state) ?? "").toLowerCase();
    ref.state = st === "destroyed" || s(machine.destroyed_at) ? "destroyed" : st === "online" ? "online" : st === "failed" || st === "error" ? "failed" : "provisioning";
    if (ref.state === "failed") ref.error = s(machine.error);
  } else ref.state = ref.action === "destroy" ? "requested" : "provisioning";
  return ref;
}

/** Human label of a node: the managed machine's name when known, else its id without the `managed-` prefix. */
export function machineLabel(nodeId: string | undefined, follow?: FollowUps): string | undefined {
  if (!nodeId) return undefined;
  const m = follow?.machines.get(nodeId);
  const name = m && (s(m.name) ?? s(m.label) ?? s(m.display_name));
  if (name) return name;
  if (m && s(m.size)) return `${s(m.size)} · ${nodeId.replace(/^managed-/, "")}`;
  return nodeId.replace(/^managed-/, "");
}

export const subagentStatusLabel: Record<SubagentStatus, string> = {
  starting: "Starting", queued: "Queued", running: "Running", done: "Done", failed: "Failed", cancelled: "Cancelled",
};
