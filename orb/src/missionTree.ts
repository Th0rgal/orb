import { harnessName } from "./harnesses";
import { isWorking } from "./missionStatus";
/** Missions launched by a mission are shown inside it, like files in a folder.
 * Forks are versions of one conversation, not launched work: the most recently
 * active version leads and earlier versions are listed inside it (`version`). */
export interface NestedMission<M> { mission: M; children: NestedMission<M>[]; version?: boolean }

type Linked = { id: string; parent_mission_id?: string | null; callback_parent_mission_id?: string | null; title?: string | null; tags?: readonly string[] | null };
type Dated = { updated_at?: string | null; created_at?: string | null };

const LEGACY_FORK_TITLE = /\s·\sfork$/i;

/** The conversation this one was forked from. Older forks were stored as
 * children titled "… · fork"; newer ones carry a `fork-of:` tag instead. */
export function forkSource(mission: Omit<Linked, "id">): string | undefined {
  const tag = mission.tags?.find(t => t.startsWith("fork-of:"))?.slice(8);
  if (tag) return tag;
  return mission.parent_mission_id && LEGACY_FORK_TITLE.test(mission.title ?? "") ? mission.parent_mission_id : undefined;
}

/** The mission that launched this one. A fork is never launched work. */
export const missionParent = (mission: Omit<Linked, "id">): string | undefined =>
  (forkSource(mission) === mission.parent_mission_id ? undefined : mission.parent_mission_id) || mission.callback_parent_mission_id || undefined;

/** A fork shares its conversation's name; versions are told apart by harness and model. */
export const forkTitle = (title: string | null | undefined): string => (title ?? "").replace(LEGACY_FORK_TITLE, "");

/** "Codex · gpt-6.1-sol": how an earlier version is told apart from the current one. */
export const versionLabel = (mission: { backend?: string | null; model_override?: string | null }): string =>
  [mission.backend ? harnessName(mission.backend) : "", mission.model_override ?? ""].filter(Boolean).join(" · ") || "Earlier version";

const activity = (mission: Dated) => Date.parse(mission.updated_at || mission.created_at || "") || 0;

/** Groups the listed forks of one conversation; maps each version to its group's leader. */
export function forkLeaders<M extends Linked & Dated>(missions: readonly M[]): Map<string, M> {
  const byId = new Map(missions.map(m => [m.id, m]));
  const root = (mission: M) => {
    const seen = new Set<string>();
    let current = mission;
    for (let source = forkSource(current); source && byId.has(source) && !seen.has(source); source = forkSource(current)) { seen.add(current.id); current = byId.get(source)!; }
    return current.id;
  };
  const groups = new Map<string, M[]>();
  for (const mission of missions) groups.set(root(mission), [...(groups.get(root(mission)) ?? []), mission]);
  const leaders = new Map<string, M>();
  for (const group of groups.values()) {
    if (group.length < 2) continue;
    const leader = group.reduce((best, m) => activity(m) > activity(best) ? m : best);
    for (const mission of group) leaders.set(mission.id, leader);
  }
  return leaders;
}

/** Roots keep the order of the list, and so do the children of each mission.
 * A mission whose parent is not in the list is held under `opts.placeholder`
 * (one stand-in per missing parent, placed where its first child would be);
 * without one, or when it returns undefined (parent confirmed gone), it is a root. */
export function nestMissions<M extends Linked & Dated>(missions: M[], opts: { placeholder?: (parentId: string, child: M) => M | undefined } = {}): NestedMission<M>[] {
  const leaders = forkLeaders(missions);
  const nodes = new Map(missions.map(mission => [mission.id, { mission, children: [] as NestedMission<M>[] }]));
  const roots: NestedMission<M>[] = [];
  const versions = new Map<string, NestedMission<M>[]>();
  const placeholders = new Map<string, NestedMission<M>>();
  for (const mission of missions) {
    const node = nodes.get(mission.id)!;
    const leader = leaders.get(mission.id);
    if (leader && leader.id !== mission.id) {
      versions.set(leader.id, [...(versions.get(leader.id) ?? []), { ...node, version: true }]);
      continue;
    }
    // A leading fork takes the place of the conversation it continues.
    const placeOf = leader ? missions.find(m => leaders.get(m.id) === leader && !forkSource(m) ) ?? mission : mission;
    const parentId = missionParent(placeOf);
    const parent = parentId ? nodes.get(parentId) : undefined;
    if (parent && parent !== node && !reaches(nodes, parent.mission, mission.id)) parent.children.push(node);
    else if (parentId && !parent && opts.placeholder) {
      // Its parent is not loaded (yet): hold it under a stand-in, never at the root.
      let held = placeholders.get(parentId);
      if (!held) {
        const stand = opts.placeholder(parentId, placeOf);
        if (stand) { held = { mission: stand, children: [] }; placeholders.set(parentId, held); roots.push(held); }
      }
      (held ? held.children : roots).push(node);
    }
    else roots.push(node);
  }
  for (const [leaderId, earlier] of versions) {
    earlier.sort((a, b) => activity(b.mission) - activity(a.mission));
    nodes.get(leaderId)!.children.push(...earlier);
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

/** Launched work inside a mission, at any depth. Earlier versions are not launched work. */
export function countNested<M>(node: NestedMission<M>, matches: (mission: M) => boolean = () => true): number {
  return node.children.reduce((sum, child) => child.version ? sum : sum + Number(matches(child.mission)) + countNested(child, matches), 0);
}

export const countVersions = <M,>(node: NestedMission<M>): number => node.children.filter(child => child.version).length;

export function holds<M extends Linked>(node: NestedMission<M>, id: string): boolean {
  return node.children.some(child => child.mission.id === id || holds(child, id));
}

/** Return the selected missions and every mission they launched, at any depth. */
export function missionSubtree<M extends Linked>(missions: readonly M[], rootIds: readonly string[]): M[] {
  const included = new Set(rootIds);
  let added = true;
  while (added) {
    added = false;
    for (const mission of missions) {
      if (included.has(mission.id)) continue;
      const parent = missionParent(mission);
      if (parent && included.has(parent)) {
        included.add(mission.id);
        added = true;
      }
    }
  }
  return missions.filter(mission => included.has(mission.id));
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


export function hasSupersededTag(tags?: readonly string[] | null): boolean {
  return Boolean(
    tags?.some(
      tag =>
        tag === "superseded" ||
        tag.startsWith("superseded_by:") ||
        tag.startsWith("superseded-by:"),
    ),
  );
}

/** True when a mission was explicitly superseded by a replacement attempt and is no longer running. */
export function isSupersededMission(mission: { status?: string | null; tags?: readonly string[] | null }): boolean {
  if (isWorking(mission.status)) return false;
  return hasSupersededTag(mission.tags);
}

/** True when a mission or any of its ancestors is superseded and this mission is not actively running. */
export function isSupersededInTree<M extends Linked & { status?: string | null; tags?: readonly string[] | null }>(
  mission: M,
  byId: ReadonlyMap<string, M>,
): boolean {
  if (isWorking(mission.status)) return false;
  if (isSupersededMission(mission)) return true;
  const seen = new Set<string>([mission.id]);
  let parent = missionParent(mission);
  while (parent && !seen.has(parent)) {
    seen.add(parent);
    const row = byId.get(parent);
    if (!row) break;
    if (isSupersededMission(row)) return true;
    parent = missionParent(row);
  }
  return false;
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

/** Parents referenced by loaded rows that the rows do not contain. */
export function missingParentIds<M extends Linked>(rows: readonly M[]): string[] {
  const ids = new Set(rows.map(m => m.id));
  const missing = new Set<string>();
  for (const row of rows) { const parent = missionParent(row); if (parent && !ids.has(parent)) missing.add(parent); }
  return [...missing];
}

/**
 * A page of missions ordered by recent activity can hold many workers while
 * their older parent falls off the page; the workers would then be listed as
 * roots. Fetch every missing ancestor by id (a parent that no longer exists
 * resolves to null) and list each one just before its first descendant, so
 * the parent takes the place its newest worker had.
 */
export async function withAncestors<M extends Linked>(rows: readonly M[], fetchById: (id: string) => Promise<M | null>, maxDepth = 8): Promise<M[]> {
  const known = new Map(rows.map(m => [m.id, m]));
  const fetched = new Map<string, M>();
  const tried = new Set<string>();
  for (let depth = 0; depth < maxDepth; depth++) {
    const wanted = missingParentIds([...known.values()]).filter(id => !tried.has(id));
    if (!wanted.length) break;
    wanted.forEach(id => tried.add(id));
    const results = await Promise.all(wanted.map(id => fetchById(id).catch(() => null)));
    for (const row of results) if (row && !known.has(row.id)) { known.set(row.id, row); fetched.set(row.id, row); }
  }
  if (!fetched.size) return [...rows];
  const out: M[] = [], placed = new Set<string>();
  const place = (row: M, seen: Set<string>) => {
    const parent = missionParent(row);
    if (parent && fetched.has(parent) && !placed.has(parent) && !seen.has(parent)) { seen.add(parent); place(fetched.get(parent)!, seen); }
    if (!placed.has(row.id)) { placed.add(row.id); out.push(row); }
  };
  for (const row of rows) place(row, new Set([row.id]));
  return out;
}
