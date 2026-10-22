/** Where a mission runs, and how a machine id reads. */

type Placed = { remote_job?: { node_id?: string | null } | null; remote_node_id?: string | null } | null | undefined;

/** The node a remote mission runs on: the live job's node, then its assignment. */
export const missionNode = (m: Placed): string | undefined => m?.remote_job?.node_id ?? m?.remote_node_id ?? undefined;

/** The node a mission is assigned to, then the live job's node. Uploads and
 * composer targets follow the assignment while a job is being replaced. */
export const missionAssignedNode = (m: Placed): string | undefined => m?.remote_node_id ?? m?.remote_job?.node_id ?? undefined;

import { createSignal } from "solid-js";

type Named = { id: string; display_name?: string | null; labels?: string[] | null; cpu_total?: number | null; mem_total_bytes?: number | null };
const [names, setNames] = createSignal<ReadonlyMap<string, string>>(new Map());
/** Remember server display names (managed machines: "small-a") so every label follows them. */
export function rememberNodeNames(nodes: Named[]) {
  const next = new Map(names());
  for (const n of nodes) if (n.display_name) next.set(n.id, n.display_name);
  if (next.size !== names().size || [...next].some(([k, v]) => names().get(k) !== v)) setNames(next);
}
/** Remote nodes provisioned by the managed-machine service. */
export const isManagedNode = (node: { id?: string; labels?: string[] | null } | null | undefined) =>
  !!node && (!!node.labels?.includes("managed") || !!node.id?.startsWith("managed-"));
/** "4 vCPU · 8 GB" from heartbeat capacity, when known. */
export const nodeSize = (n: Named) => [n.cpu_total ? `${n.cpu_total} vCPU` : "", n.mem_total_bytes ? `${Math.round(n.mem_total_bytes / 1024 ** 3)} GB` : ""].filter(Boolean).join(" · ");

export const nodeLabel = (id: string) =>
  names().get(id) ??
  (id === "core" ? "Core"
  : id === "local" ? "This computer"
  : id === "dgx-spark" ? "DGX Spark"
  : id === "dgx-spark-admin" ? "DGX Spark · Administration"
  : id);
