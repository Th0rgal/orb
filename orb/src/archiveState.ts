import { archiveMission, reopenMission, type Mission } from "./api";
import { missionSubtree } from "./missionTree";
import { isArchived, isWorking } from "./missionStatus";

/** Conversations an archive or restore of `mission` acts on: restore reopens the
 *  archived members of its subtree; archive takes every not-yet-archived member.
 *  Throws when archiving would stop running work. Shared by the HTML sidebar
 *  (`changeArchiveState`) and the native sidebar menu. */
export function archiveStateTargets(mission: Mission, known: readonly Mission[], restore: boolean, skip: (id: string) => boolean = () => false): Mission[] {
  const subtree = missionSubtree(known, [mission.id]);
  const full = subtree.some(m => m.id === mission.id) ? subtree : [mission, ...subtree];
  if (!restore && full.some(m => isWorking(m.status))) throw new Error("Stop or finish this agent before archiving it.");
  return restore
    ? [mission, ...full.filter(m => m.id !== mission.id && isArchived(m.status))]
    : full.filter(m => !isArchived(m.status) && !skip(m.id));
}

/** Sends the status change for `targets` (from `archiveStateTargets`). */
export async function applyArchiveState(mission: Mission, targets: readonly Mission[], restore: boolean): Promise<void> {
  if (!restore && targets.length > 1 && targets.some(t => t.id === mission.id)) {
    // Core cascades status=acknowledged to parent_mission_id descendants;
    // archiving the root first avoids N redundant POSTs while still
    // archiving callback-only children and confirming local origins.
    await archiveMission(mission.id);
    await Promise.all(targets.filter(t => t.id !== mission.id).map(t => archiveMission(t.id)));
  } else {
    await Promise.all(targets.map(t => restore ? reopenMission(t.id) : archiveMission(t.id)));
  }
}
