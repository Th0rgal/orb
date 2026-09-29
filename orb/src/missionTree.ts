/** Missions launched by a mission are shown inside it, like files in a folder. */
export interface NestedMission<M> { mission: M; children: NestedMission<M>[] }

type Linked = { id: string; parent_mission_id?: string | null };

/** Roots keep the order of the list, and so do the children of each mission.
 * A mission whose parent is not in the list stays a root. */
export function nestMissions<M extends Linked>(missions: M[]): NestedMission<M>[] {
  const nodes = new Map(missions.map(mission => [mission.id, { mission, children: [] as NestedMission<M>[] }]));
  const roots: NestedMission<M>[] = [];
  for (const mission of missions) {
    const node = nodes.get(mission.id)!;
    const parent = mission.parent_mission_id ? nodes.get(mission.parent_mission_id) : undefined;
    if (parent && parent !== node && !reaches(nodes, parent.mission, mission.id)) parent.children.push(node);
    else roots.push(node);
  }
  return roots;
}

/** True when following parents from `from` arrives at `target`: nesting there would close a loop. */
function reaches<M extends Linked>(nodes: Map<string, NestedMission<M>>, from: M, target: string): boolean {
  const seen = new Set<string>();
  for (let current: M | undefined = from; current && !seen.has(current.id); current = current.parent_mission_id ? nodes.get(current.parent_mission_id)?.mission : undefined) {
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
