/** Where a mission runs, and how a machine id reads. */

type Placed = { remote_job?: { node_id?: string | null } | null; remote_node_id?: string | null } | null | undefined;

/** The node a remote mission runs on: the live job's node, then its assignment. */
export const missionNode = (m: Placed): string | undefined => m?.remote_job?.node_id ?? m?.remote_node_id ?? undefined;

/** The node a mission is assigned to, then the live job's node. Uploads and
 * composer targets follow the assignment while a job is being replaced. */
export const missionAssignedNode = (m: Placed): string | undefined => m?.remote_node_id ?? m?.remote_job?.node_id ?? undefined;

export const nodeLabel = (id: string) =>
  id === "core" ? "Core"
  : id === "local" ? "This computer"
  : id === "dgx-spark" ? "DGX Spark"
  : id === "dgx-spark-admin" ? "DGX Spark · Administration"
  : id;
