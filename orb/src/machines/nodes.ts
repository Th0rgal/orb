/** Where a mission runs, and how a machine id reads. */

type Placed = { remote_job?: { node_id?: string | null } | null; remote_node_id?: string | null } | null | undefined;

/** The node a remote mission runs on: the live job's node, then its assignment. */
export const missionNode = (m: Placed): string | undefined => m?.remote_job?.node_id ?? m?.remote_node_id ?? undefined;

/** The node a mission is assigned to, then the live job's node. Uploads and
 * composer targets follow the assignment while a job is being replaced. */
export const missionAssignedNode = (m: Placed): string | undefined => m?.remote_node_id ?? m?.remote_job?.node_id ?? undefined;

import { createSignal } from "solid-js";

type Named = { id: string; display_name?: string | null; labels?: string[] | null; cpu_total?: number | null; mem_total_bytes?: number | null };
const KNOWN_PROVIDERS = new Set(["boat", "hetzner", "vastai", "scaleway"]);
const [names, setNames] = createSignal<ReadonlyMap<string, string>>(new Map());
const [providers, setProviders] = createSignal<ReadonlyMap<string, string>>(new Map());

function parseLabelsProvider(labels?: readonly string[] | null): string | undefined {
  for (const raw of labels ?? []) {
    const l = raw.trim().toLowerCase();
    if (l.startsWith("provider=")) return l.slice("provider=".length);
    if (KNOWN_PROVIDERS.has(l)) return l;
  }
  return undefined;
}

/** Remember server display names and provider labels so every machine picker follows them. */
export function rememberNodeNames(nodes: Named[]) {
  const next = new Map(names());
  const nextProv = new Map(providers());
  for (const n of nodes) {
    if (n.display_name) next.set(n.id, n.display_name);
    const p = parseLabelsProvider(n.labels);
    if (p) nextProv.set(n.id, p);
  }
  if (next.size !== names().size || [...next].some(([k, v]) => names().get(k) !== v)) setNames(next);
  if (nextProv.size !== providers().size || [...nextProv].some(([k, v]) => providers().get(k) !== v)) setProviders(nextProv);
}
/** Remote nodes provisioned by the managed-machine service. */
export const isManagedNode = (node: { id?: string; labels?: readonly string[] | null } | null | undefined) =>
  !!node && (!!node.labels?.includes("managed") || !!node.id?.startsWith("managed-"));
/** Cloud provider of a managed node ("boat", "hetzner", "vastai", "scaleway"), when known. */
export const nodeProvider = (node: { id?: string; labels?: readonly string[] | null } | null | undefined): string | undefined =>
  node ? parseLabelsProvider(node.labels) ?? (node.id ? providers().get(node.id) : undefined) : undefined;
/** Group heading for managed fleet nodes: "Managed (boat.dev)", "Managed (Hetzner)", or "Managed cloud". */
export function managedFleetLabel(nodes: readonly ({ id?: string; labels?: readonly string[] | null } | null | undefined)[]): string {
  const managed = nodes.filter(isManagedNode);
  const seen = new Set(managed.map(n => nodeProvider(n) ?? "boat"));
  if (seen.size <= 1) {
    const [only] = seen;
    if (!only || only === "boat") return "Managed (boat.dev)";
    if (only === "hetzner") return "Managed (Hetzner)";
    if (only === "vastai") return "Managed (Vast.ai)";
    if (only === "scaleway") return "Managed (Scaleway)";
  }
  return "Managed cloud";
}
/** "4 vCPU · 8 GB" from heartbeat capacity, when known. */
export const nodeSize = (n: Named) => [n.cpu_total ? `${n.cpu_total} vCPU` : "", n.mem_total_bytes ? `${Math.round(n.mem_total_bytes / 1024 ** 3)} GB` : ""].filter(Boolean).join(" · ");

export type Machine = {
  id: string;
  name: string;
  host: string;
  user: string;
  port: number;
  locked?: boolean;
  note: string;
};

/** Paloma compute fleet that can take missions. From paloma-backends / paloma-ssh-servers. */
export const MACHINES: Machine[] = [
  { id: "local", name: "This Mac", host: "localhost", user: "local", port: 22, locked: true, note: "This computer" },
  { id: "agent-core", name: "agent-core", host: "65.109.98.246", user: "root", port: 22, note: "Control plane · Core" },
  { id: "ashur", name: "ashur", host: "188.40.69.160", user: "root", port: 22, note: "db0.starknet.id · Lean/Docker" },
  { id: "babylon", name: "babylon", host: "54.36.175.109", user: "ubuntu", port: 22, note: "db1.starknet.id · Lean" },
  { id: "nippur", name: "nippur", host: "37.187.92.183", user: "ubuntu", port: 22, note: "db2.starknet.id · Lean/Verity" },
  { id: "old-agent", name: "old-agent", host: "95.216.112.253", user: "root", port: 22, note: "Compute leaf · sandboxed-node" },
  { id: "dgx-spark", name: "dgx-spark", host: "10.88.0.2", user: "th0rgal", port: 22, note: "spark-de79 · lean-mesh · GPU" },
];

export const nodeLabel = (id: string) =>
  names().get(id) ??
  (id === "core" ? "Core"
  : id === "local" ? "This computer"
  : id === "dgx-spark" ? "DGX Spark"
  : id === "dgx-spark-admin" ? "DGX Spark · Administration"
  : id);
