import { api, getApiUrl, getMission, connectionVersion } from './api';
import { copyText } from './clipboard';
import { missionMoveKey, moveOptimistically, previewMove, withMovedMissions } from './moves';
import { missionParent } from './missionTree';
const prefix = 'orb:cut-mission:';
export async function cutMission(id: string): Promise<string> {
  const text = prefix + JSON.stringify({ id, backend: getApiUrl(), nonce: crypto.randomUUID() });
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
export async function moveMission(id: string, project: string, folder: string, fromProject: string | null = null): Promise<void> {
  const version = connectionVersion();
  await moveOptimistically(missionMoveKey(id), { kind: 'mission', fromProject, toProject: project, path: folder }, async () => {
    const mission = await getMission(id);
    if (version !== connectionVersion()) throw new Error('Connection changed. Cut the conversation again.');
    const tags = (mission.tags ?? []).filter(tag => !tag.startsWith('orb-folder:'));
    if (folder) tags.push(`orb-folder:${folder}`);
    await api(`/api/control/missions/${encodeURIComponent(id)}/project`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ project, tags }),
    });
    window.dispatchEvent(new CustomEvent('orb:mission-moved', { detail: { id, project, tags } }));
  });
}

type Known = { id: string; project?: string | null; parent_mission_id?: string | null; callback_parent_mission_id?: string | null; title?: string | null };
export type MovePlan = { id: string; from: string | null; folder: string }[];
/**
 * What moving `ids` to `project/folder` must write. Selected missions whose
 * ancestor is also selected travel with that ancestor. Launched missions
 * (children, at any depth) live in their parent's project, so a move to
 * another project takes the whole subtree along; inside the same project
 * they already follow their parent and need no write.
 */
export function planMissionMoves(ids: readonly string[], project: string, folder: string, known: readonly Known[]): MovePlan {
  const byId = new Map(known.map(m => [m.id, m]));
  const selected = new Set(ids);
  const hasSelectedAncestor = (id: string) => {
    const seen = new Set<string>([id]);
    for (let p = byId.get(id) && missionParent(byId.get(id)!); p && !seen.has(p); p = byId.get(p) ? missionParent(byId.get(p)!) : undefined) {
      if (selected.has(p)) return true;
      seen.add(p);
    }
    return false;
  };
  const roots = [...new Set(ids)].filter(id => !hasSelectedAncestor(id));
  const plan: MovePlan = roots.map(id => ({ id, from: byId.get(id)?.project ?? null, folder }));
  const included = new Set(roots);
  for (let added = true; added;) {
    added = false;
    for (const m of known) {
      const parent = missionParent(m);
      if (included.has(m.id) || !parent || !included.has(parent)) continue;
      included.add(m.id); added = true;
      if ((m.project ?? null) !== project) plan.push({ id: m.id, from: m.project ?? null, folder: '' });
    }
  }
  return plan;
}
/**
 * Move every mission of `plan` at once: all rows show at their destination
 * immediately, requests run in parallel, and each failed one returns to its
 * old place on its own. Resolves with the ids that failed.
 */
export async function moveMissions(plan: MovePlan, project: string): Promise<{ id: string; error: unknown }[]> {
  for (const step of plan) previewMove(missionMoveKey(step.id), { kind: 'mission', fromProject: step.from, toProject: project, path: step.folder });
  const results = await Promise.allSettled(plan.map(step => moveMission(step.id, project, step.folder, step.from)));
  return results.flatMap((r, i) => r.status === 'rejected' ? [{ id: plan[i].id, error: r.reason }] : []);
}
