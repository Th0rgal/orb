import { missionNode, rememberNodeNames } from "./machines/nodes";
import { Show, createMemo, createRoot, createSignal } from "solid-js";
import type { Mission, RemoteNodeView } from "./api";
import { Bot } from "./sidebarIcons";

/** How busy each machine is, derived once from lists Orb already keeps fresh
 * (running missions, fleet status, local metrics). Menus only read the result. */
export interface MachineLoad { sessions: number; freeMemory?: number }

// Only executing agents: queued or resuming work has no agent process yet.
const LIVE = new Set(["active", "running", "starting"]);
const [missions, setMissions] = createSignal<Mission[]>([]);
const [fleet, setFleet] = createSignal<RemoteNodeView[]>([]);
const [localMemory, setLocalMemory] = createSignal<number>();

export const recordMissions = (rows: Mission[]) => { setMissions(rows); };
export const recordFleet = (rows: RemoteNodeView[]) => { setFleet(rows); rememberNodeNames(rows); };
export const recordLocalMemory = (free: number | undefined) => { setLocalMemory(free); };

/** `client`, `core`, or a node id: the keys both machine menus use. */
export function missionMachine(mission: Mission): string | undefined {
  if (mission.backend?.startsWith("cloud_")) return undefined;
  if (mission.tags?.includes("placement:client")) return "client";
  return missionNode(mission) ?? "core";
}

const loads = createRoot(() => createMemo(() => {
  const table = new Map<string, MachineLoad>();
  const at = (key: string) => { let load = table.get(key); if (!load) table.set(key, load = { sessions: 0 }); return load; };
  for (const mission of missions()) {
    if (!LIVE.has(mission.status)) continue;
    const machine = missionMachine(mission);
    if (machine) at(machine).sessions++;
  }
  for (const node of fleet()) if (node.mem_available_bytes != null) at(node.id).freeMemory = node.mem_available_bytes;
  const free = localMemory();
  if (free != null) at("client").freeMemory = free;
  return table;
}));

const idle: MachineLoad = { sessions: 0 };
/** The administration entry is the same computer as the node it administers. */
const hardware = (machine: string) => machine === "dgx-spark-admin" ? "dgx-spark" : machine === "local" ? "client" : machine;
export function machineLoad(machine: string): MachineLoad {
  const table = loads();
  const own = table.get(machine), shared = table.get(hardware(machine));
  if (!own) return shared ?? idle;
  if (!shared || shared === own) return own;
  return { sessions: own.sessions + shared.sessions, freeMemory: own.freeMemory ?? shared.freeMemory };
}

/** Fewest running agents first, then most free memory. Equal rows keep their order. */
export function byLeastLoaded<T>(rows: T[], machine: (row: T) => string): T[] {
  return rows
    .map((row, index) => ({ row, index, load: machineLoad(machine(row)) }))
    .sort((a, b) => a.load.sessions - b.load.sessions
      || (b.load.freeMemory ?? -1) - (a.load.freeMemory ?? -1)
      || a.index - b.index)
    .map(entry => entry.row);
}

export const MIN_AUTO_NODE_MEM_BYTES = 8 * 1024 ** 3;
export const MIN_AUTO_NODE_DISK_BYTES = 20 * 1024 ** 3;

export type AutoSchedulableNodeInput = {
  id: string;
  status?: string | null;
  cordoned?: boolean | null;
  labels?: string[] | null;
  mem_available_bytes?: number | null;
  disk_available_bytes?: number | null;
  disk_pressure_pinned?: boolean | null;
  quarantined_harnesses?: string[] | null;
};

/** Whether a compute node may be selected automatically without an explicit pin (mirrors Core `select_node_auto`). */
export function isAutoSchedulableNode(node: AutoSchedulableNodeInput, backend?: string | null): boolean {
  if (node.status !== "online" || node.cordoned || node.disk_pressure_pinned) return false;
  const labels = node.labels ?? [];
  if (labels.includes("manual-only") || labels.includes("managed") || labels.includes("small")) return false;
  if (node.mem_available_bytes != null && node.mem_available_bytes < MIN_AUTO_NODE_MEM_BYTES) return false;
  if (node.disk_available_bytes != null && node.disk_available_bytes < MIN_AUTO_NODE_DISK_BYTES) return false;
  if (backend && node.quarantined_harnesses?.includes(backend)) return false;
  return true;
}

/** First automatically schedulable compute node from the sorted list (online, uncordoned, roomy, non-manual). */
export function firstAvailableNodeId(nodes: AutoSchedulableNodeInput[], backend?: string | null): string | undefined {
  const usable = nodes.filter(node => isAutoSchedulableNode(node, backend));
  return byLeastLoaded(usable, node => node.id)[0]?.id;
}

const gib = (bytes: number) => `${(bytes / 1024 ** 3).toFixed(bytes < 10 * 1024 ** 3 ? 1 : 0)} GiB`;
export function machineLoadTitle(machine: string): string {
  const load = machineLoad(machine);
  const agents = load.sessions === 0 ? "No agent running" : load.sessions === 1 ? "1 agent running" : `${load.sessions} agents running`;
  return load.freeMemory == null ? agents : `${agents} · ${gib(load.freeMemory)} of memory free`;
}

/** `2 ×` and the agent icon. Nothing is shown for an idle machine. */
export function MachineLoadBadge(p: { machine: string }) {
  const load = () => machineLoad(p.machine);
  return <Show when={load().sessions > 0}>
    <span class="machine-load" title={machineLoadTitle(p.machine)} aria-label={machineLoadTitle(p.machine)}>
      {load().sessions}<span aria-hidden="true">×</span><Bot size={11} />
    </span>
  </Show>;
}
