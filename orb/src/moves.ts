/**
 * Optimistic moves shared by every view, like `renames.ts`. A mission, file
 * or folder moved to another project (or folder) shows at its destination at
 * once wherever lists are read through `withMovedMissions` / `movedMission` /
 * `filesMovedAway` / `filesMovedInto`.
 *
 * Mission moves are monotonically revisioned via `orb_placement_merge_step`
 * (`missionHierarchy.ts`): once `save()` commits the server's authoritative
 * `placement_revision`, the pending overlay clears immediately without any
 * timer heuristic, and stale pre-move list refreshes are rejected by revision.
 * File moves retain `MOVE_CONFIRM_MS` / `settleMove` until directory listings
 * refresh.
 */
import { createSignal } from "solid-js";
import { ApprovalTransferConfirmationRequiredError } from "./api";
import {
  allocatePlacementOpId,
  normalizeMissionFolder,
  rollbackOptimisticPlacement,
  stageOptimisticPlacement,
} from "./missionHierarchy";
import { notify } from "./toast";
import { errorText, log } from "./log";

export type PendingMove = {
  kind: "mission" | "file";
  fromProject: string | null;
  toProject: string;
  /** Destination folder (missions) or destination path (files). */
  path: string;
  /** Files: the source path; `directory` for folders. */
  fromPath?: string;
  directory?: boolean;
  acceptedAt?: number;
  /** Monotonic client op id for mission moves (`orb_placement_merge_step`). */
  opId?: number;
};

export const MOVE_CONFIRM_MS = 30_000;
const [pending, setPending] = createSignal<ReadonlyMap<string, PendingMove>>(new Map());

export const missionMoveKey = (id: string) => `mission:${id}`;
export const fileMoveKey = (slug: string, path: string) => `file:${slug}:${path}`;

function update(key: string, next: PendingMove | undefined) {
  setPending(map => {
    const copy = new Map(map);
    if (next) copy.set(key, next); else copy.delete(key);
    return copy;
  });
}
function clearIf(key: string, entry: PendingMove) {
  if (pending().get(key) === entry) update(key, undefined);
}

export const pendingMove = (key: string) => pending().get(key);
export const pendingMoves = () => pending();

const PROJECTED_MOVE = Symbol.for("orb.projectedMove");

type Placed = {
  id: string;
  project?: string | null;
  folder?: string | null;
  placement_revision?: number;
  parent_mission_id?: string | null;
  callback_parent_mission_id?: string | null;
  tags?: string[] | null;
  [PROJECTED_MOVE]?: true;
};

/** `mission` at its pending destination, if it is being moved. */
export function movedMission<T extends Placed>(mission: T): T {
  const key = missionMoveKey(mission.id);
  const move = pending().get(key);
  if (!move) return mission;
  const targetFolder = normalizeMissionFolder(move.path);
  if (
    (mission.project ?? null) === move.toProject
    && normalizeMissionFolder(mission.folder) === targetFolder
    && mission[PROJECTED_MOVE]
  ) {
    return mission;
  }
  const out = { ...mission, project: move.toProject, folder: targetFolder };
  Object.defineProperty(out, PROJECTED_MOVE, { value: true, enumerable: false });
  return out;
}

/** `rows` with pending moves applied; unchanged rows (and the array) keep their identity. */
export function withMovedMissions<T extends Placed>(rows: readonly T[]): T[] {
  if (!pending().size) return rows as T[];
  let changed = false;
  const out = rows.map(row => { const next = movedMission(row); if (next !== row) changed = true; return next; });
  return changed ? out : (rows as T[]);
}

/** Missions moving into `project` that `known` holds under another project. */
export function missionsMovedInto<T extends Placed>(project: string, known: readonly T[]): T[] {
  const out: T[] = [], seen = new Set<string>();
  for (const row of known) {
    if (seen.has(row.id)) continue;
    const move = pending().get(missionMoveKey(row.id));
    if (move?.toProject === project && (row.project ?? null) !== project) { seen.add(row.id); out.push(movedMission(row)); }
  }
  return out;
}
/** Whether `mission` is being moved out of `project`. */
export const movingOutOf = (id: string, project: string) => { const move = pending().get(missionMoveKey(id)); return !!move && move.toProject !== project; };

const parentOf = (path: string) => path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
const baseOf = (path: string) => path.slice(path.lastIndexOf("/") + 1);

/** Names in `slug:dir` that are being moved elsewhere. */
export function filesMovedAway(slug: string, dir: string): Set<string> {
  const out = new Set<string>();
  for (const [key, move] of pending()) {
    if (move.kind !== "file" || !move.fromPath || !key.startsWith(`file:${slug}:`)) continue;
    if (parentOf(move.fromPath) === dir && !(move.toProject === slug && move.path === move.fromPath)) out.add(baseOf(move.fromPath));
  }
  return out;
}
/** Entries arriving in `toProject:dir`. */
export function filesMovedInto(toProject: string, dir: string): { name: string; kind: "dir" | "file" }[] {
  const out: { name: string; kind: "dir" | "file" }[] = [];
  for (const move of pending().values()) {
    if (move.kind === "file" && move.toProject === toProject && parentOf(move.path) === dir) out.push({ name: baseOf(move.path), kind: move.directory ? "dir" : "file" });
  }
  return out;
}

function missionIdOfKey(key: string): string | null {
  return key.startsWith("mission:") ? key.slice("mission:".length) : null;
}

/**
 * Show one or more related moves (e.g. a mission and its launched subtree)
 * now and persist them via a single `save` call. On failure every entry
 * returns to its old place together, one error toast is shown (unless a
 * cross-project secret approval confirmation dialog is requested) and the
 * error is rethrown.
 */
export async function moveBatchOptimistically(
  items: readonly { key: string; move: PendingMove }[],
  save: (opId: number) => Promise<unknown>,
  label = "the conversation",
): Promise<void> {
  if (!items.length) {
    await save(0);
    return;
  }
  const hasMission = items.some(i => i.move.kind === "mission");
  const opId = hasMission ? allocatePlacementOpId() : 0;
  const staged = items.map(({ key, move }) => {
    const normPath = move.kind === "mission" ? normalizeMissionFolder(move.path) : move.path;
    const entry: PendingMove = {
      ...move,
      path: normPath,
      acceptedAt: undefined,
      ...(move.kind === "mission" ? { opId } : {}),
    };
    const mid = move.kind === "mission" ? missionIdOfKey(key) : null;
    if (mid) stageOptimisticPlacement(mid, move.toProject, normPath, opId, { project: move.fromProject });
    return { key, entry, mid };
  });
  for (const { key, entry } of staged) update(key, entry);
  try {
    await save(opId);
  } catch (error) {
    for (const { key, entry, mid } of staged) {
      if (mid && entry.opId) rollbackOptimisticPlacement(mid, entry.opId);
      clearIf(key, entry);
    }
    if (!(error instanceof ApprovalTransferConfirmationRequiredError)) {
      const primary = items[0]!;
      log.warn(`move.${primary.move.kind}`, errorText(error), { key: primary.key, to: primary.move.toProject });
      notify({ kind: "error", key: `move:${primary.key}`, title: `Couldn’t move ${label}`, message: errorText(error) });
    }
    throw error;
  }
  const now = Date.now();
  const fileAccepted: { key: string; entry: PendingMove }[] = [];
  for (const { key, entry } of staged) {
    if (entry.kind === "mission") {
      // Authoritative `placement_revision` is now committed in `missionHierarchy.ts`;
      // clear the transient overlay immediately without a 30s confirmation window.
      clearIf(key, entry);
      continue;
    }
    if (pending().get(key) !== entry) continue;
    const next = { ...entry, acceptedAt: now };
    update(key, next);
    fileAccepted.push({ key, entry: next });
  }
  if (fileAccepted.length) {
    setTimeout(() => {
      for (const { key, entry } of fileAccepted) clearIf(key, entry);
    }, MOVE_CONFIRM_MS);
  }
}

/**
 * Show the move now and send it with `save`. On failure the item returns to
 * its old place, an error toast is shown and the error is rethrown.
 */
export async function moveOptimistically(key: string, move: PendingMove, save: (opId: number) => Promise<unknown>, label = "the conversation"): Promise<void> {
  await moveBatchOptimistically([{ key, move }], save, label);
}

/** Show a move that will be sent shortly (a batch shows all its items at once). */
export function previewMove(key: string, move: PendingMove): void {
  const normPath = move.kind === "mission" ? normalizeMissionFolder(move.path) : move.path;
  update(key, { ...move, path: normPath, acceptedAt: undefined });
}

/** Forget a move once its listings were reloaded or cancelled. */
export function settleMove(key: string): void {
  const existing = pending().get(key);
  const mid = existing?.kind === "mission" ? missionIdOfKey(key) : null;
  if (mid && existing?.opId) rollbackOptimisticPlacement(mid, existing.opId);
  update(key, undefined);
}

/** Test hook. */
export function resetMoves(): void { setPending(new Map()); }
