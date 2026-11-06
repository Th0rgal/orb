import {
  LOCAL_PLACEMENT_CLIENT_ID,
  applyAncestorCachePlacements,
  btwParentId,
  commitAuthoritativePlacements,
  connectionVersion,
  getApiUrl,
  moveMissionsBatch,
  normalizeMissionFolder,
  resolveLocalAckOpId,
  type ApprovalTransferPolicy,
  type MissionPlacementItem,
  type PlacementCommitItem,
} from "./api";
import { copyText } from "./clipboard";
import { missionMoveKey, moveBatchOptimistically, moveOptimistically, previewMove, withMovedMissions } from "./moves";
import { forkLeaders, missionParent } from "./missionTree";
import { usageTelemetry } from "./usageTelemetry";

const prefix = "orb:cut-mission:";
export function makeCutMission(id: string): string {
  return prefix + JSON.stringify({ id, backend: getApiUrl(), nonce: crypto.randomUUID() });
}
export async function cutMission(id: string, clipboardData?: DataTransfer | null): Promise<string> {
  const text = makeCutMission(id);
  if (clipboardData) { clipboardData.setData("text/plain", text); return text; }
  await copyText(text);
  return text;
}
export function readCutMission(text: string, backend: string): string | null {
  if (!text.startsWith(prefix)) return null;
  try {
    const value = JSON.parse(text.slice(prefix.length));
    return value.backend === backend && typeof value.id === "string" && /^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(value.id) ? value.id : null;
  } catch { return null; }
}

// Optimistic moves (moves.ts): every view shows the mission in its new place
// at once; list refreshes still carrying the old project/folder cannot move it back.
export const applyPendingMoves = withMovedMissions;

/** Commit authoritative placement updates from either `POST /api/control/missions/move`,
 * `POST /api/projects/:slug/file/transfer`, or the `mission_placement_changed` stream event. */
export function applyServerPlacementEvent(
  moves: readonly MissionPlacementItem[],
  clientOpId?: number | null,
  clientId?: string | null,
): PlacementCommitItem[] {
  if (!moves?.length) return [];
  const ackOpId = resolveLocalAckOpId(clientOpId, clientId);
  const accepted = commitAuthoritativePlacements(moves, ackOpId);
  if (!accepted.length) return [];
  applyAncestorCachePlacements(accepted);
  window.dispatchEvent(new CustomEvent("orb:mission-placement-changed", { detail: { moves: accepted } }));
  return accepted;
}

async function executeMoveBatch(
  rootIds: readonly string[],
  project: string,
  folder: string,
  version: number,
  opId: number,
  descendantIds?: readonly string[],
  approvalPolicy: ApprovalTransferPolicy = "check",
): Promise<void> {
  if (version !== connectionVersion()) throw new Error("Connection changed. Cut the conversation again.");
  const normFolder = normalizeMissionFolder(folder);
  const res = await moveMissionsBatch({
    mission_ids: [...rootIds],
    project,
    folder: normFolder,
    approval_policy: approvalPolicy,
    ...(opId > 0 ? { client_op_id: opId, client_id: LOCAL_PLACEMENT_CLIENT_ID } : {}),
    ...(descendantIds?.length ? { descendant_ids: [...descendantIds] } : {}),
  });
  applyServerPlacementEvent(res.moved, res.client_op_id ?? opId, res.client_id ?? LOCAL_PLACEMENT_CLIENT_ID);
}

export async function moveMission(
  id: string,
  project: string,
  folder: string,
  fromProject: string | null = null,
  _includeDescendants = false,
  approvalPolicy: ApprovalTransferPolicy = "check",
): Promise<void> {
  const version = connectionVersion();
  const normFolder = normalizeMissionFolder(folder);
  await moveOptimistically(
    missionMoveKey(id),
    { kind: "mission", fromProject, toProject: project, path: normFolder },
    (opId) => executeMoveBatch([id], project, normFolder, version, opId, undefined, approvalPolicy),
  );
}

type Known = {
  id: string;
  project?: string | null;
  folder?: string | null;
  placement_revision?: number;
  parent_mission_id?: string | null;
  callback_parent_mission_id?: string | null;
  title?: string | null;
  tags?: readonly string[] | null;
  status?: string | null;
  updated_at?: string | null;
  created_at?: string | null;
};
export type MovePlanStep = {
  id: string;
  from: string | null;
  folder: string;
  includeDescendants?: boolean;
  /** Set on child projection entries persisted atomically by their root step's batch write. */
  viaRootId?: string;
  /** Client-known callback descendants (`callback_parent_mission_id`) forwarded with the root write. */
  descendantIds?: string[];
};
export type MovePlan = MovePlanStep[];

/**
 * What moving `ids` to `project/folder` must project and write. Selected
 * missions whose ancestor is also selected travel with that ancestor. When a
 * selected mission leads a co-located `fork-of:` conversation group in its
 * source project, the earlier versions folded into that single sidebar row
 * travel with it; selecting an individual earlier version moves only that
 * version. Launched missions (children at any depth and `/btw` side sessions)
 * travel with their root conversation with `folder: ""`.
 */
export function planMissionMoves(ids: readonly string[], project: string, folder: string, known: readonly Known[]): MovePlan {
  const normFolder = normalizeMissionFolder(folder);
  const byId = new Map(known.map(m => [m.id, m]));
  const projectBucket = (p: string | null | undefined) => p || "default";
  const buckets = new Map<string, Known[]>();
  for (const m of known) {
    const bucket = projectBucket(m.project);
    buckets.set(bucket, [...(buckets.get(bucket) ?? []), m]);
  }
  const leadersByBucket = new Map<string, Map<string, Known>>();
  for (const [bucket, list] of buckets) leadersByBucket.set(bucket, forkLeaders(list));
  const expandedIds: string[] = [];
  const seenExpanded = new Set<string>();
  const pushExpanded = (id: string) => {
    if (!seenExpanded.has(id)) {
      seenExpanded.add(id);
      expandedIds.push(id);
    }
  };
  for (const id of ids) {
    pushExpanded(id);
    const target = byId.get(id);
    if (!target) continue;
    const bucket = projectBucket(target.project);
    const leaders = leadersByBucket.get(bucket);
    if (leaders?.get(id)?.id === id) {
      for (const sibling of buckets.get(bucket) ?? []) {
        if (leaders.get(sibling.id)?.id === id) pushExpanded(sibling.id);
      }
    }
  }
  const selected = new Set(expandedIds);
  const parentLink = (m: Known) => missionParent(m) ?? btwParentId(m);
  const hasSelectedAncestor = (id: string) => {
    const seen = new Set<string>([id]);
    for (let p = byId.get(id) && parentLink(byId.get(id)!); p && !seen.has(p); p = byId.get(p) ? parentLink(byId.get(p)!) : undefined) {
      if (selected.has(p)) return true;
      seen.add(p);
    }
    return false;
  };
  const roots = expandedIds.filter(id => !hasSelectedAncestor(id));
  const rootOf = new Map<string, string>(roots.map(r => [r, r]));
  const childrenByRoot = new Map<string, MovePlanStep[]>();
  const callbackIdsByRoot = new Map<string, string[]>();
  const childSteps: MovePlan = [];
  for (let added = true; added;) {
    added = false;
    for (const m of known) {
      const parent = parentLink(m);
      if (rootOf.has(m.id) || !parent || !rootOf.has(parent)) continue;
      const rootId = rootOf.get(parent)!;
      rootOf.set(m.id, rootId);
      added = true;
      if (m.callback_parent_mission_id && parent === m.callback_parent_mission_id && parent !== m.parent_mission_id) {
        callbackIdsByRoot.set(rootId, [...(callbackIdsByRoot.get(rootId) ?? []), m.id]);
      }
      if ((m.project ?? null) !== project || normalizeMissionFolder(m.folder) !== "") {
        const step: MovePlanStep = {
          id: m.id,
          from: m.project ?? null,
          folder: "",
          viaRootId: rootId,
        };
        childSteps.push(step);
        childrenByRoot.set(rootId, [...(childrenByRoot.get(rootId) ?? []), step]);
      }
    }
  }
  const plan: MovePlan = roots.map(id => {
    const target = byId.get(id);
    const from = target?.project ?? null;
    const isNested = !!(target && parentLink(target));
    const effectiveFolder = isNested ? "" : normFolder;
    const cross = from !== project || (childrenByRoot.get(id)?.some(c => c.from !== project) ?? false);
    const cbIds = callbackIdsByRoot.get(id);
    return {
      id,
      from,
      folder: effectiveFolder,
      ...(cross ? { includeDescendants: true } : {}),
      ...(cbIds?.length ? { descendantIds: cbIds } : {}),
    };
  });
  plan.push(...childSteps);
  return plan;
}

/**
 * Move every mission of `plan` at once: all rows (roots and loaded children)
 * show at their destination immediately, roots sharing a destination folder
 * execute in a single atomic `POST /api/control/missions/move` request, and if
 * a batch fails its roots and every covered child projection roll back together.
 * Resolves with the ids that failed.
 */
export async function moveMissions(
  plan: MovePlan,
  project: string,
  options?: { approvalPolicy?: ApprovalTransferPolicy },
): Promise<{ id: string; error: unknown }[]> {
  if (!plan.length) return [];
  usageTelemetry.action("sidebar_move", "sidebar", plan.length);
  for (const step of plan) {
    previewMove(missionMoveKey(step.id), {
      kind: "mission",
      fromProject: step.from,
      toProject: project,
      path: step.folder,
    });
  }
  const childrenByRoot = new Map<string, MovePlanStep[]>();
  for (const step of plan) {
    if (!step.viaRootId) continue;
    childrenByRoot.set(step.viaRootId, [...(childrenByRoot.get(step.viaRootId) ?? []), step]);
  }
  const roots = plan.filter(step => !step.viaRootId);
  const groupsByFolder = new Map<string, MovePlanStep[]>();
  for (const root of roots) {
    const norm = normalizeMissionFolder(root.folder);
    groupsByFolder.set(norm, [...(groupsByFolder.get(norm) ?? []), root]);
  }
  const version = connectionVersion();
  const approvalPolicy = options?.approvalPolicy ?? "check";
  const groupEntries = [...groupsByFolder.entries()];
  const results = await Promise.allSettled(groupEntries.map(([destFolder, folderRoots]) => {
    const coveredSteps = folderRoots.flatMap(root => [root, ...(childrenByRoot.get(root.id) ?? [])]);
    const descendantIds = [...new Set(folderRoots.flatMap(root => root.descendantIds ?? []))];
    const batch = coveredSteps.map(step => ({
      key: missionMoveKey(step.id),
      move: { kind: "mission" as const, fromProject: step.from, toProject: project, path: step.folder },
    }));
    return moveBatchOptimistically(
      batch,
      (opId) => executeMoveBatch(
        folderRoots.map(r => r.id),
        project,
        destFolder,
        version,
        opId,
        descendantIds,
        approvalPolicy,
      ),
    );
  }));
  return results.flatMap((r, i) => {
    if (r.status !== "rejected") return [];
    const [, folderRoots] = groupEntries[i]!;
    const coveredSteps = folderRoots.flatMap(root => [root, ...(childrenByRoot.get(root.id) ?? [])]);
    return coveredSteps.map(step => ({ id: step.id, error: r.reason }));
  });
}
