/**
 * Optimistic renames shared by every view. A rename shows at once wherever
 * the mission or project title is read through `renamedTitle` /
 * `withRenamedTitles`; list refreshes that still carry the old title cannot
 * undo it. The entry clears when the server reports the new title, after
 * `RENAME_CONFIRM_MS` once the request succeeded, or at once when it failed
 * (the old title returns and an error toast explains why).
 */
import { createSignal } from "solid-js";
import { notify } from "./toast";
import { errorText, log } from "./log";

export type RenameKind = "mission" | "project";
type Pending = { title: string; previous: string | null; acceptedAt?: number };

export const RENAME_CONFIRM_MS = 30_000;
const [pending, setPending] = createSignal<ReadonlyMap<string, Pending>>(new Map());
const keyOf = (kind: RenameKind, id: string) => `${kind}:${id}`;

function update(key: string, next: Pending | undefined) {
  setPending(map => {
    const copy = new Map(map);
    if (next) copy.set(key, next); else copy.delete(key);
    return copy;
  });
}
function clearIf(key: string, entry: Pending) {
  if (pending().get(key) === entry) update(key, undefined);
}

/** The title to show: a pending rename wins over what the server last listed. */
export function renamedTitle<T extends string | null | undefined>(kind: RenameKind, id: string, server: T): string | T {
  const key = keyOf(kind, id);
  const entry = pending().get(key);
  if (!entry) return server;
  if (entry.acceptedAt !== undefined && server === entry.title) {
    // The server confirmed it; later renames elsewhere must show again.
    queueMicrotask(() => clearIf(key, entry));
    return server;
  }
  return entry.title;
}

/** `rows` with pending renames applied; unchanged rows keep their identity. */
export function withRenamedTitles<T extends { title?: string | null }>(kind: RenameKind, rows: readonly T[], id: (row: T) => string): T[] {
  const map = pending();
  if (!map.size) return rows as T[];
  let changed = false;
  const out = rows.map(row => {
    const title = renamedTitle(kind, id(row), row.title ?? null);
    if (title === (row.title ?? null)) return row;
    changed = true;
    return { ...row, title };
  });
  return changed ? out : (rows as T[]);
}

export const isRenamePending = (kind: RenameKind, id: string) => pending().has(keyOf(kind, id));

/**
 * Show `title` now and send it with `save`. On failure the previous title
 * comes back, an error toast is shown and the error is rethrown.
 */
export async function renameOptimistically(kind: RenameKind, id: string, title: string, previous: string | null, save: () => Promise<unknown>): Promise<void> {
  const key = keyOf(kind, id);
  const entry: Pending = { title, previous };
  update(key, entry);
  try {
    await save();
  } catch (error) {
    clearIf(key, entry);
    log.warn(`rename.${kind}`, errorText(error), { id });
    notify({ kind: "error", key: `rename:${key}`, title: kind === "mission" ? "Couldn’t rename the conversation" : "Couldn’t rename the project", message: errorText(error) });
    throw error;
  }
  if (pending().get(key) !== entry) return;
  const accepted = { ...entry, acceptedAt: Date.now() };
  update(key, accepted);
  setTimeout(() => clearIf(key, accepted), RENAME_CONFIRM_MS);
}

/** Test hook. */
export function resetRenames(): void { setPending(new Map()); }
