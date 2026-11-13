/** Where a mission runs, and how a machine id reads. */

type Placed = { remote_job?: { node_id?: string | null } | null; remote_node_id?: string | null } | null | undefined;

/** The node a remote mission runs on: the live job's node, then its assignment. */
export const missionNode = (m: Placed): string | undefined => m?.remote_job?.node_id ?? m?.remote_node_id ?? undefined;

/** The node a mission is assigned to, then the live job's node. Uploads and
 * composer targets follow the assignment while a job is being replaced. */
export const missionAssignedNode = (m: Placed): string | undefined => m?.remote_node_id ?? m?.remote_job?.node_id ?? undefined;

import { createSignal } from "solid-js";

type Named = { id: string; display_name?: string | null; owner_kind?: string | null; labels?: string[] | null; cpu_total?: number | null; mem_total_bytes?: number | null };
const KNOWN_PROVIDERS = new Set(["boat", "leanci", "hetzner", "vastai", "scaleway", "colab"]);
const [names, setNames] = createSignal<ReadonlyMap<string, string>>(new Map());
const [providers, setProviders] = createSignal<ReadonlyMap<string, string>>(new Map());
const [owners, setOwners] = createSignal<ReadonlyMap<string, string>>(new Map());

function parseLabelsProvider(labels?: readonly string[] | null): string | undefined {
  for (const raw of labels ?? []) {
    const l = raw.trim().toLowerCase();
    if (l.startsWith("provider=")) return l.slice("provider=".length);
    if (KNOWN_PROVIDERS.has(l)) return l;
  }
  return undefined;
}

export function parseLabelsOwner(labels?: readonly string[] | null): string | undefined {
  for (const raw of labels ?? []) {
    const l = raw.trim().toLowerCase();
    if (l.startsWith("owner=")) return l.slice("owner=".length);
  }
  return undefined;
}

/** Remember server display names, provider labels, and ownership kinds so every machine picker follows them. */
export function rememberNodeNames(nodes: Named[]) {
  const next = new Map(names());
  const nextProv = new Map(providers());
  const nextOwn = new Map(owners());
  for (const n of nodes) {
    if (n.display_name) next.set(n.id, n.display_name);
    const p = parseLabelsProvider(n.labels);
    if (p) nextProv.set(n.id, p);
    const o = (n.owner_kind ?? parseLabelsOwner(n.labels) ?? "").trim().toLowerCase();
    if (o) nextOwn.set(n.id, o);
  }
  if (next.size !== names().size || [...next].some(([k, v]) => names().get(k) !== v)) setNames(next);
  if (nextProv.size !== providers().size || [...nextProv].some(([k, v]) => providers().get(k) !== v)) setProviders(nextProv);
  if (nextOwn.size !== owners().size || [...nextOwn].some(([k, v]) => owners().get(k) !== v)) setOwners(nextOwn);
}

/** Sync live managed-machine records into the shared node name/owner map. */
export function rememberManagedMachines(
  machines: readonly { id: string; node_id?: string | null; name?: string | null; provider?: string | null; owner_kind?: string | null; owner_mission_id?: string | null; requested_by_mission_id?: string | null }[],
) {
  const next = new Map(names());
  const nextProv = new Map(providers());
  const nextOwn = new Map(owners());
  for (const m of machines) {
    const ids = [...new Set([m.node_id ?? "", `managed-${m.id}`].filter(Boolean))];
    const kind = m.owner_mission_id || m.requested_by_mission_id ? "mission" : (m.owner_kind ?? "").trim().toLowerCase();
    const prov = (m.provider ?? "").trim().toLowerCase();
    for (const id of ids) {
      if (m.name) next.set(id, m.name);
      if (prov) nextProv.set(id, prov);
      if (kind) nextOwn.set(id, kind);
    }
  }
  if (next.size !== names().size || [...next].some(([k, v]) => names().get(k) !== v)) setNames(next);
  if (nextProv.size !== providers().size || [...nextProv].some(([k, v]) => providers().get(k) !== v)) setProviders(nextProv);
  if (nextOwn.size !== owners().size || [...nextOwn].some(([k, v]) => owners().get(k) !== v)) setOwners(nextOwn);
}

/** Remote nodes provisioned by the managed-machine service. */
export const isManagedNode = (node: { id?: string; labels?: readonly string[] | null } | null | undefined) =>
  !!node && (!!node.labels?.includes("managed") || !!node.id?.startsWith("managed-"));

/** Managed VMs started on demand by an agent or claimed by a mission (`owner=mission`). */
export const isAgentSpawnedManagedNode = (
  node: { id?: string; labels?: readonly string[] | null; owner_kind?: string | null } | null | undefined,
): boolean => {
  if (!isManagedNode(node)) return false;
  const kind = (node?.owner_kind ?? parseLabelsOwner(node?.labels) ?? (node?.id ? owners().get(node.id) : undefined) ?? "").trim().toLowerCase();
  return kind === "mission";
};

/** Managed VMs explicitly started by the user (`owner=user` or unclaimed). */
export const isUserManagedNode = (
  node: { id?: string; labels?: readonly string[] | null; owner_kind?: string | null } | null | undefined,
): boolean => isManagedNode(node) && !isAgentSpawnedManagedNode(node);

export function managedProviderShortLabel(provider?: string | null): string {
  const key = (provider ?? "").trim().toLowerCase();
  if (key === "boat") return "boat.dev";
  if (key === "leanci") return "lean.ci";
  if (key === "hetzner") return "Hetzner";
  if (key === "vastai") return "Vast.ai";
  if (key === "scaleway") return "Scaleway";
  if (key === "colab" || key === "google-colab") return "Google Colab";
  return provider?.trim() || "boat.dev";
}

export function parseAutoManagedTarget(raw?: string | null): { provider?: string; size?: string } | null {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) return null;
  if (trimmed.toLowerCase() === "auto-managed") return {};
  if (!trimmed.toLowerCase().startsWith("auto-managed:")) return null;
  const rest = trimmed.slice("auto-managed:".length).trim();
  if (!rest) return {};
  const parts = rest.split(":").map(s => s.trim()).filter(Boolean);
  if (parts.length === 1) return { provider: parts[0].toLowerCase() };
  if (parts.length === 2) return { provider: parts[0].toLowerCase(), size: parts[1] };
  return null;
}

export const isAutoManagedTarget = (raw?: string | null): boolean => parseAutoManagedTarget(raw) !== null;

export const formatAutoManagedTarget = (provider: string, size: string): string =>
  `auto-managed:${provider.trim().toLowerCase()}:${size.trim()}`;
/** Cloud provider of a managed node ("boat", "hetzner", "vastai", "scaleway"), when known. */
export const nodeProvider = (node: { id?: string; labels?: readonly string[] | null } | null | undefined): string | undefined =>
  node ? parseLabelsProvider(node.labels) ?? (node.id ? providers().get(node.id) : undefined) : undefined;
/** Auto-collapse managed provider groups in the Remote fleet card once they exceed 3 VMs. */
export const MANAGED_FLEET_COLLAPSE_AFTER = 3;

export function managedProviderFleetLabel(provider?: string | null): string {
  const key = (provider ?? "boat").trim().toLowerCase() || "boat";
  if (key === "boat") return "Managed (boat.dev)";
  if (key === "leanci") return "Managed (lean.ci)";
  if (key === "hetzner") return "Managed (Hetzner)";
  if (key === "vastai") return "Managed (Vast.ai)";
  if (key === "scaleway") return "Managed (Scaleway)";
  if (key === "colab" || key === "google-colab") return "Managed (Google Colab)";
  return `Managed (${provider})`;
}

export interface ManagedFleetGroup<N> {
  provider: string;
  label: string;
  nodes: N[];
}

/** Group managed fleet nodes by provider in canonical order. */
export function groupManagedNodesByProvider<N extends { id?: string; labels?: readonly string[] | null }>(
  nodes: readonly N[],
): ManagedFleetGroup<N>[] {
  const buckets = new Map<string, N[]>();
  for (const n of nodes) {
    if (!isManagedNode(n)) continue;
    const key = (nodeProvider(n) ?? "boat").trim().toLowerCase() || "boat";
    const list = buckets.get(key);
    if (list) list.push(n);
    else buckets.set(key, [n]);
  }
  const order = ["boat", "leanci", "hetzner", "vastai", "scaleway", "colab"];
  for (const key of buckets.keys()) {
    if (!order.includes(key)) order.push(key);
  }
  return order
    .filter(key => (buckets.get(key)?.length ?? 0) > 0)
    .map(key => ({ provider: key, label: managedProviderFleetLabel(key), nodes: buckets.get(key)! }));
}

/** Compact summary for a managed fleet provider header: "16 online · 15 active" or "1 online". */
export function managedFleetGroupSummary(nodes: readonly { status?: string | null; active_jobs?: number | null }[]): string {
  const online = nodes.filter(n => n.status === "online").length;
  const active = nodes.reduce((sum, n) => sum + (n.active_jobs ?? 0), 0);
  const head = online === nodes.length ? `${online} online` : `${online}/${nodes.length} online`;
  return active > 0 ? `${head} · ${active} active` : head;
}

/** Right-side slot badge for a fleet node row: "2 / 6 active · 1 queued", "2 active", or undefined. */
export function formatNodeSlotBadge(node?: { active_jobs?: number | null; capacity_total?: number | null; queued_jobs?: number | null } | null): string | undefined {
  if (!node || node.active_jobs == null) return undefined;
  const head = node.capacity_total != null && node.capacity_total > 0
    ? `${node.active_jobs} / ${node.capacity_total} active`
    : `${node.active_jobs} active`;
  return node.queued_jobs != null && node.queued_jobs > 0 ? `${head} · ${node.queued_jobs} queued` : head;
}

/** Validate a live static-node capacity draft (`1..=256`). */
export function parseNodeCapacityDraft(raw: string): number | null {
  const trimmed = raw.trim();
  if (!/^\d+$/.test(trimmed)) return null;
  const value = Number(trimmed);
  return Number.isInteger(value) && value >= 1 && value <= 256 ? value : null;
}

/** Group heading for managed fleet nodes: "Managed (boat.dev)", "Managed (Hetzner)", or "Managed cloud". */
export function managedFleetLabel(nodes: readonly ({ id?: string; labels?: readonly string[] | null } | null | undefined)[]): string {
  const managed = nodes.filter(isManagedNode);
  const seen = new Set(managed.map(n => (nodeProvider(n) ?? "boat").trim().toLowerCase() || "boat"));
  if (seen.size <= 1) {
    const [only] = seen;
    return managedProviderFleetLabel(only);
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
  { id: "uruk", name: "uruk", host: "95.216.112.253", user: "root", port: 22, note: "Compute leaf · sandboxed-node" },
  { id: "nimrud", name: "nimrud", host: "51.195.100.33", user: "ubuntu", port: 22, note: "Compute leaf · sandboxed-node" },
  { id: "dgx-spark", name: "dgx-spark", host: "10.88.0.2", user: "th0rgal", port: 22, note: "spark-de79 · lean-mesh · GPU" },
];

export const nodeLabel = (id: string) => {
  const auto = parseAutoManagedTarget(id);
  if (auto) {
    if (auto.provider && auto.size) return `${managedProviderShortLabel(auto.provider)} · ${auto.size === "default" ? "medium" : auto.size}`;
    if (auto.provider) return managedProviderShortLabel(auto.provider);
    return "Cloud VM";
  }
  return names().get(id) ??
    (id === "core" ? "Core"
    : id === "local" ? "This computer"
    : id === "dgx-spark" ? "DGX Spark"
    : id === "dgx-spark-admin" ? "DGX Spark · Administration"
    : id);
};

export const isAdminOnlyNode = (
  node:
    | { id?: string | null; admin_only?: boolean | null; core_colocated?: boolean | null; labels?: readonly string[] | null }
    | null
    | undefined,
): boolean => {
  if (!node) return false;
  if (node.id === "core" || node.id === "agent-core" || node.id === "dgx-spark-admin") return true;
  if (node.admin_only === true || node.core_colocated === true) return true;
  return Boolean(node.labels?.some(l => l.trim().toLowerCase() === "admin-only"));
};

