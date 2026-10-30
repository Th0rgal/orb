/**
 * Optimistic moves shared by every view, like `renames.ts`. A mission, file
 * or folder moved to another project (or folder) shows at its destination at
 * once wherever lists are read through `withMovedMissions` / `movedMission` /
 * `filesMovedAway` / `filesMovedInto`. List refreshes that still carry the
 * old place cannot snap it back. An entry clears when the server reports the
 * new place is committed by its owner, `MOVE_CONFIRM_MS` after success, or when
 * it failed (the item returns and an error toast explains why).
 */
import { createSignal } from "solid-js";
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
};

export const MOVE_CONFIRM_MS = 30_000;
const [pending, setPending] = createSignal<ReadonlyMap<string, PendingMove>>(new Map());
const FOLDER = "orb-folder:";

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

type Placed = { id: string; project?: string | null; tags?: string[] | null };
const folderOf = (tags?: string[] | null) => tags?.find(t => t.startsWith(FOLDER))?.slice(FOLDER.length) ?? "";
const withFolder = (tags: string[] | null | undefined, folder: string) => [...(tags ?? []).filter(t => !t.startsWith(FOLDER)), ...(folder ? [`${FOLDER}${folder}`] : [])];

/** `mission` at its pending destination, if it is being moved. */
export function movedMission<T extends Placed>(mission: T): T {
  const key = missionMoveKey(mission.id);
  const move = pending().get(key);
  if (!move) return mission;
  if ((mission.project ?? null) === move.toProject && folderOf(mission.tags) === move.path) {
    // A projected row may be read again. Rendering is not acknowledgement;
    // only the owner may settle the move after committing canonical placement.
    return mission;
  }
  return { ...mission, project: move.toProject, tags: withFolder(mission.tags, move.path) };
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

/**
 * Show one or more related moves (e.g. a mission and its launched subtree)
 * now and persist them via a single `save` call. On failure every entry
 * returns to its old place together, one error toast is shown and the error
 * is rethrown.
 */
export async function moveBatchOptimistically(
  items: readonly { key: string; move: PendingMove }[],
  save: () => Promise<unknown>,
  label = "the conversation",
): Promise<void> {
  if (!items.length) {
    await save();
    return;
  }
  const staged = items.map(({ key, move }) => ({ key, entry: { ...move, acceptedAt: undefined } as PendingMove }));
  for (const { key, entry } of staged) update(key, entry);
  try {
    await save();
  } catch (error) {
    for (const { key, entry } of staged) clearIf(key, entry);
    const primary = items[0]!;
    log.warn(`move.${primary.move.kind}`, errorText(error), { key: primary.key, to: primary.move.toProject });
    notify({ kind: "error", key: `move:${primary.key}`, title: `Couldn’t move ${label}`, message: errorText(error) });
    throw error;
  }
  const now = Date.now();
  const accepted: { key: string; entry: PendingMove }[] = [];
  for (const { key, entry } of staged) {
    if (pending().get(key) !== entry) continue;
    const next = { ...entry, acceptedAt: now };
    update(key, next);
    accepted.push({ key, entry: next });
  }
  setTimeout(() => {
    for (const { key, entry } of accepted) clearIf(key, entry);
  }, MOVE_CONFIRM_MS);
}

/**
 * Show the move now and send it with `save`. On failure the item returns to
 * its old place, an error toast is shown and the error is rethrown.
 */
export async function moveOptimistically(key: string, move: PendingMove, save: () => Promise<unknown>, label = "the conversation"): Promise<void> {
  await moveBatchOptimistically([{ key, move }], save, label);
}

/** Show a move that will be sent shortly (a batch shows all its items at once). */
export function previewMove(key: string, move: PendingMove): void { update(key, { ...move, acceptedAt: undefined }); }

/** Forget a file move once its listings were reloaded from the server. */
export function settleMove(key: string): void { update(key, undefined); }

/** Test hook. */
export function resetMoves(): void { setPending(new Map()); }
