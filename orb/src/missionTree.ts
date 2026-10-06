/** Missions launched by a mission are shown inside it, like files in a folder. */
export interface NestedMission<M> { mission: M; children: NestedMission<M>[] }

type Linked = { id: string; parent_mission_id?: string | null; callback_parent_mission_id?: string | null };
export const missionParent = (mission: Linked): string | undefined => mission.parent_mission_id || mission.callback_parent_mission_id || undefined;

/** Roots keep the order of the list, and so do the children of each mission.
 * A mission whose parent is not in the list stays a root. */
export function nestMissions<M extends Linked>(missions: M[]): NestedMission<M>[] {
  const nodes = new Map(missions.map(mission => [mission.id, { mission, children: [] as NestedMission<M>[] }]));
  const roots: NestedMission<M>[] = [];
  for (const mission of missions) {
    const node = nodes.get(mission.id)!;
    const parent = missionParent(mission) ? nodes.get(missionParent(mission)!) : undefined;
    if (parent && parent !== node && !reaches(nodes, parent.mission, mission.id)) parent.children.push(node);
    else roots.push(node);
  }
  return roots;
}

/** True when following parents from `from` arrives at `target`: nesting there would close a loop. */
function reaches<M extends Linked>(nodes: Map<string, NestedMission<M>>, from: M, target: string): boolean {
  const seen = new Set<string>();
  for (let current: M | undefined = from; current && !seen.has(current.id); current = missionParent(current) ? nodes.get(missionParent(current)!)?.mission : undefined) {
    if (current.id === target) return true;
    seen.add(current.id);
  }
  return false;
}

export function countNested<M>(node: NestedMission<M>, matches: (mission: M) => boolean = () => true): number {
  return node.children.reduce((sum, child) => sum + Number(matches(child.mission)) + countNested(child, matches), 0);
}

export function holds<M extends Linked>(node: NestedMission<M>, id: string): boolean {
  return node.children.some(child => child.mission.id === id || holds(child, id));
}

/** Keep archived parents as context for visible workers, without restoring them. */
export function missionTreeRows<M extends Linked>(missions:M[],visible:(mission:M)=>boolean):M[]{
 const byId=new Map(missions.map(m=>[m.id,m]));
 const retained=new Set(missions.filter(visible).map(m=>m.id));
 for(const mission of missions.filter(visible)){
  const seen=new Set([mission.id]);
  let parent=missionParent(mission);
  while(parent&&!seen.has(parent)){
   seen.add(parent);const row=byId.get(parent);if(!row)break;
   retained.add(parent);parent=missionParent(row);
  }
 }
 return missions.filter(m=>retained.has(m.id));
}

/** A retained archived ancestor has one presentation row, in the main tree. */
export function archiveOnlyRows<M extends {id:string;status:string}>(archived:M[],main:readonly {id:string}[]):M[]{
 const visible=new Set(main.map(m=>m.id));
 return archived.filter(m=>m.status==="acknowledged"&&!visible.has(m.id));
}

export const ARCHIVE_DAY_MS = 24 * 60 * 60 * 1000;
export const ARCHIVE_WEEK_MS = 7 * ARCHIVE_DAY_MS;

/** Filter archived missions by minimum age (`updated_at` falling back to `created_at`). */
export function filterArchivedMissionsByAge<M extends { updated_at?: string | null; created_at?: string | null }>(
  rows: readonly M[],
  maxAgeMs?: number,
  now = Date.now(),
): M[] {
  if (!maxAgeMs) return [...rows];
  const cutoff = now - maxAgeMs;
  return rows.filter(mission => {
    const raw = mission.updated_at || mission.created_at || "";
    const timestamp = Date.parse(raw);
    return Number.isFinite(timestamp) && timestamp <= cutoff;
  });
}

/** Expand target mission IDs with any known descendants from loaded rows. */
export function expandMissionDescendants<M extends Linked>(
  ids: readonly string[],
  rows: readonly M[],
): string[] {
  const out = new Set(ids);
  if (!out.size || !rows.length) return [...out];
  let added = true;
  while (added) {
    added = false;
    for (const row of rows) {
      if (out.has(row.id)) continue;
      const parent = missionParent(row);
      if (parent && out.has(parent)) {
        out.add(row.id);
        added = true;
      }
    }
  }
  return [...out];
}
