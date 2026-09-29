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
export const recordFleet = (rows: RemoteNodeView[]) => { setFleet(rows); };
export const recordLocalMemory = (free: number | undefined) => { setLocalMemory(free); };

/** `client`, `core`, or a node id: the keys both machine menus use. */
export function missionMachine(mission: Mission): string | undefined {
  if (mission.backend?.startsWith("cloud_")) return undefined;
  if (mission.tags?.includes("placement:client")) return "client";
  return mission.remote_job?.node_id ?? mission.remote_node_id ?? "core";
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
