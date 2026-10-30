import { api, getApiUrl, getMission, connectionVersion } from './api';
import { copyText } from './clipboard';
import { missionMoveKey, moveBatchOptimistically, moveOptimistically, previewMove, withMovedMissions } from './moves';
import { forkLeaders, missionParent } from './missionTree';
import { usageTelemetry } from './usageTelemetry';
const prefix = 'orb:cut-mission:';
export function makeCutMission(id: string): string {
  return prefix + JSON.stringify({ id, backend: getApiUrl(), nonce: crypto.randomUUID() });
}
export async function cutMission(id: string, clipboardData?: DataTransfer | null): Promise<string> {
  const text = makeCutMission(id);
  if (clipboardData) { clipboardData.setData('text/plain', text); return text; }
  await copyText(text);
  return text;
}
export function readCutMission(text: string, backend: string): string | null {
  if (!text.startsWith(prefix)) return null;
  try {
    const value = JSON.parse(text.slice(prefix.length));
    return value.backend === backend && typeof value.id === 'string' && /^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(value.id) ? value.id : null;
  } catch { return null; }
}
// Optimistic moves (moves.ts): every view shows the mission in its new place
// at once; list refreshes still carrying the old project cannot move it back.
export const applyPendingMoves = withMovedMissions;
async function writeMissionProject(
  id: string,
  project: string,
  folder: string,
  version: number,
  includeDescendants = false,
  descendantIds?: readonly string[],
  coveredChildren: readonly MovePlanStep[] = [],
): Promise<void> {
  const mission = await getMission(id);
  if (version !== connectionVersion()) throw new Error('Connection changed. Cut the conversation again.');
  const tags = (mission.tags ?? []).filter(tag => !tag.startsWith('orb-folder:'));
  if (folder) tags.push(`orb-folder:${folder}`);
  await api(`/api/control/missions/${encodeURIComponent(id)}/project`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      project,
      tags,
      ...(includeDescendants ? { include_descendants: true } : {}),
      ...(descendantIds?.length ? { descendant_ids: descendantIds } : {}),
    }),
  });
  window.dispatchEvent(new CustomEvent('orb:mission-moved', { detail: { id, project, tags } }));
  for (const child of coveredChildren) {
    window.dispatchEvent(new CustomEvent('orb:mission-moved', {
      detail: { id: child.id, project, ...(child.tags ? { tags: child.tags } : {}) },
    }));
  }
}

export async function moveMission(id: string, project: string, folder: string, fromProject: string | null = null, includeDescendants = false): Promise<void> {
  const version = connectionVersion();
  await moveOptimistically(
    missionMoveKey(id),
    { kind: 'mission', fromProject, toProject: project, path: folder },
    () => writeMissionProject(id, project, folder, version, includeDescendants),
  );
}

type Known = {
  id: string;
  project?: string | null;
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
  /** Set on child projection entries persisted atomically by their root step's `include_descendants` write. */
  viaRootId?: string;
  /** Post-move child tags (`orb-folder:*` stripped) when known from sidebar state. */
  tags?: string[];
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
 * version. Launched missions (children, at any depth) live in their parent's
 * project, so a move to another project projects the whole subtree immediately
 * while persisting it atomically through each root's `include_descendants` write.
 */
export function planMissionMoves(ids: readonly string[], project: string, folder: string, known: readonly Known[]): MovePlan {
  const byId = new Map(known.map(m => [m.id, m]));
  const projectBucket = (p: string | null | undefined) => p || 'default';
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
  const hasSelectedAncestor = (id: string) => {
    const seen = new Set<string>([id]);
    for (let p = byId.get(id) && missionParent(byId.get(id)!); p && !seen.has(p); p = byId.get(p) ? missionParent(byId.get(p)!) : undefined) {
      if (selected.has(p)) return true;
      seen.add(p);
    }
    return false;
  };
  const roots = expandedIds.filter(id => !hasSelectedAncestor(id));
  const rootOf = new Map<string, string>(roots.map(r => [r, r]));
  const crossProjectByRoot = new Map<string, MovePlanStep[]>();
  const callbackIdsByRoot = new Map<string, string[]>();
  const childSteps: MovePlan = [];
  for (let added = true; added;) {
    added = false;
    for (const m of known) {
      const parent = missionParent(m);
      if (rootOf.has(m.id) || !parent || !rootOf.has(parent)) continue;
      const rootId = rootOf.get(parent)!;
      rootOf.set(m.id, rootId);
      added = true;
      if (m.callback_parent_mission_id && parent === m.callback_parent_mission_id && parent !== m.parent_mission_id) {
        callbackIdsByRoot.set(rootId, [...(callbackIdsByRoot.get(rootId) ?? []), m.id]);
      }
      if ((m.project ?? null) !== project) {
        const childTags = m.tags ? m.tags.filter(t => !t.startsWith('orb-folder:')) : undefined;
        const step: MovePlanStep = {
          id: m.id,
          from: m.project ?? null,
          folder: '',
          viaRootId: rootId,
          ...(childTags ? { tags: childTags } : {}),
        };
        childSteps.push(step);
        crossProjectByRoot.set(rootId, [...(crossProjectByRoot.get(rootId) ?? []), step]);
      }
    }
  }
  const plan: MovePlan = roots.map(id => {
    const from = byId.get(id)?.project ?? null;
    const cross = from !== project || (crossProjectByRoot.get(id)?.length ?? 0) > 0;
    const cbIds = cross ? callbackIdsByRoot.get(id) : undefined;
    return {
      id,
      from,
      folder,
      ...(cross ? { includeDescendants: true } : {}),
      ...(cbIds?.length ? { descendantIds: cbIds } : {}),
    };
  });
  plan.push(...childSteps);
  return plan;
}
/**
 * Move every mission of `plan` at once: all rows (roots and loaded children)
 * show at their destination immediately, each root subtree executes as a
 * single atomic server request, and if a subtree request fails its root and
 * every covered child projection roll back together. Resolves with the ids
 * that failed.
 */
export async function moveMissions(plan: MovePlan, project: string): Promise<{ id: string; error: unknown }[]> {
  if (plan.length) usageTelemetry.action('sidebar_move', 'sidebar', plan.length);
  for (const step of plan) previewMove(missionMoveKey(step.id), { kind: 'mission', fromProject: step.from, toProject: project, path: step.folder });
  const childrenByRoot = new Map<string, MovePlanStep[]>();
  for (const step of plan) {
    if (!step.viaRootId) continue;
    childrenByRoot.set(step.viaRootId, [...(childrenByRoot.get(step.viaRootId) ?? []), step]);
  }
  const roots = plan.filter(step => !step.viaRootId);
  const version = connectionVersion();
  const results = await Promise.allSettled(roots.map(root => {
    const children = childrenByRoot.get(root.id) ?? [];
    const batch = [root, ...children].map(step => ({
      key: missionMoveKey(step.id),
      move: { kind: 'mission' as const, fromProject: step.from, toProject: project, path: step.folder },
    }));
    return moveBatchOptimistically(
      batch,
      () => writeMissionProject(root.id, project, root.folder, version, !!root.includeDescendants, root.descendantIds, children),
    );
  }));
  return results.flatMap((r, i) => {
    if (r.status !== 'rejected') return [];
    const root = roots[i]!;
    const children = childrenByRoot.get(root.id) ?? [];
    return [root, ...children].map(step => ({ id: step.id, error: r.reason }));
  });
}
