import { createSignal } from "solid-js";
import { archiveMission, reopenMission, type Mission } from "./api";
import { missionSubtree } from "./missionTree";
import { isArchived, isWorking } from "./missionStatus";

export type PendingArchive = { status: string; acceptedAt?: number };
export const ARCHIVE_CONFIRM_MS = 15_000;

const [pending, setPending] = createSignal<ReadonlyMap<string, PendingArchive>>(new Map());
const editPending = (fn: (copy: Map<string, PendingArchive>) => boolean) =>
  setPending(map => { const copy = new Map(map); return fn(copy) ? copy : map; });

export const pendingArchives = () => pending();
export const pendingArchiveStatus = (id: string): string | undefined => pending().get(id)?.status;
export const isArchivePending = (id: string): boolean => {
  const entry = pending().get(id);
  return entry !== undefined && entry.acceptedAt === undefined;
};

export function stagePendingArchive(ids: readonly string[], status: string): ReadonlyMap<string, PendingArchive> {
  const staged = new Map<string, PendingArchive>();
  if (ids.length) editPending(copy => {
    for (const id of ids) { const entry: PendingArchive = { status }; staged.set(id, entry); copy.set(id, entry); }
    return true;
  });
  return staged;
}

export function confirmPendingArchive(staged: ReadonlyMap<string, PendingArchive>): void {
  if (!staged.size) return;
  const now = Date.now(), accepted: Array<[string, PendingArchive]> = [];
  editPending(copy => {
    let changed = false;
    for (const [id, entry] of staged) {
      if (copy.get(id) !== entry) continue;
      const next: PendingArchive = { status: entry.status, acceptedAt: now };
      copy.set(id, next); accepted.push([id, next]); changed = true;
    }
    return changed;
  });
  for (const [id, entry] of accepted) {
    setTimeout(() => editPending(copy => copy.get(id) === entry ? copy.delete(id) : false), ARCHIVE_CONFIRM_MS);
  }
}

export function rollbackPendingArchive(staged: ReadonlyMap<string, PendingArchive>): void {
  if (!staged.size) return;
  editPending(copy => {
    let changed = false;
    for (const [id, entry] of staged) if (copy.get(id) === entry) { copy.delete(id); changed = true; }
    return changed;
  });
}

export function withArchiveStatuses<T extends { id: string; status: string }>(rows: readonly T[]): T[] {
  const map = pending();
  if (!map.size) return rows as T[];
  let changed = false;
  const out = rows.map(row => {
    const entry = map.get(row.id);
    if (!entry || entry.status === row.status) return row;
    changed = true;
    return { ...row, status: entry.status };
  });
  return changed ? out : (rows as T[]);
}

export function resetPendingArchives(): void { setPending(new Map()); }

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
