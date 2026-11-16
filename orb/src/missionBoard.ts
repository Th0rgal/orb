import type { MissionBoardSummary } from "./api";
import { authoritativePlacement } from "./missionHierarchy";

// The metadata route has no revision. Snapshot the single placement owner before
// starting a read, and reject responses spanning a committed move (including ABA).
export function boardPlacementSnapshot(): Map<string, number> {
  return new Map(boardPlacementEntries());
}
import { boardPlacementEntries } from "./missionHierarchy";
export function staleBoardListing(snapshot: ReadonlyMap<string, number>, rows: readonly MissionBoardSummary[] = []): boolean {
  const ids = new Set(rows.map(row => row.mission_id));
  return boardPlacementEntries().some(([id, revision]) => (ids.size === 0 || ids.has(id)) && revision !== (snapshot.get(id) ?? 0));
}
export function visibleBoards(rows: readonly MissionBoardSummary[], project: string): MissionBoardSummary[] {
  return rows.filter(row => {
    const placement = authoritativePlacement(row.mission_id);
    return !placement || placement.project === project;
  }).sort((a, b) => a.updated_at === b.updated_at
    ? (a.mission_id < b.mission_id ? -1 : a.mission_id > b.mission_id ? 1 : 0)
    : (a.updated_at > b.updated_at ? -1 : 1));
}
