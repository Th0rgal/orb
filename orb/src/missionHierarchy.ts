/**
 * Sticky mission hierarchy. Spec: orb/docs/specs/sidebar-hierarchy.md.
 *
 * Missions reach the Orb from many places (list polls, per-project pages,
 * single reads, PATCH/POST responses, the desktop journal, stream stubs,
 * optimistic edits). Not all of them carry the fields that place a mission
 * under its parent: Core derives `callback_parent_mission_id` only on its list
 * and read handlers, journal rows carry no lineage at all, and a status stub
 * carries nothing but the status. A row without its link is drawn at the
 * project root for one render, then snaps back under its parent: the flicker.
 *
 * Every source therefore goes through this module:
 *  - `observeMission` remembers each link the first time any payload has it;
 *  - `withHierarchy` puts remembered links back on a payload that lacks them;
 *  - `mergeMission` is the one merge (full row or partial patch) every store uses;
 *  - `reparentMission` is the only way to change or clear a remembered link.
 */
import { createSignal } from "solid-js";
import { forkSource } from "./missionTree";
import { orbHierarchyMergeStep, orbPlacementMergeStep, type PlacementSourceKind } from "./orbKernel";
import { shallowEqual } from "./poll";

export type HierarchyFields = {
  id: string;
  parent_mission_id?: string | null;
  callback_parent_mission_id?: string | null;
  tags?: readonly string[] | null;
  title?: string | null;
  project?: string | null;
  folder?: string | null;
  placement_revision?: number;
  status?: string;
};

/** Normalize a mission folder path (`""` for project root, `"a/b"` for nested folders). */
export function normalizeMissionFolder(raw?: string | null): string {
  if (!raw) return "";
  const parts: string[] = [];
  for (const seg of raw.trim().replace(/\\/g, "/").split("/")) {
    const clean = seg.trim();
    if (!clean || clean === "." || clean === "..") continue;
    parts.push(clean);
  }
  return parts.join("/");
}

export type PlacementCommitInput = {
  mission_id: string;
  project?: string | null;
  folder?: string | null;
  placement_revision: number;
};

export type PlacementCommitItem = {
  mission_id: string;
  project: string | null;
  folder: string;
  placement_revision: number;
};

type PlacementState = {
  project: string | null;
  folder: string;
  rev: number;
  pendingOpId: number;
  rollback?: { project: string | null; folder: string; rev: number };
};

const placements = new Map<string, PlacementState>();
let nextClientOpId = 0;

export function allocatePlacementOpId(): number {
  nextClientOpId = nextClientOpId >= 0xffff_fffe ? 1 : nextClientOpId + 1;
  return nextClientOpId;
}

const normalizeProject = (project?: string | null): string | null => {
  if (project === undefined || project === null) return null;
  const trimmed = project.trim();
  return trimmed ? trimmed : null;
};

const hasNestedParent = (id: string, m?: HierarchyFields): boolean => {
  const link = links.get(id);
  const p = nonEmpty(m?.parent_mission_id) ?? link?.parent;
  const title = m?.title !== undefined && m.title !== null ? m.title : seen.get(id)?.title;
  const tags = m?.tags ?? link?.tags;
  const fork = forkSource({ parent_mission_id: p, title, tags });
  if (p && p !== fork) return true;
  if (nonEmpty(m?.callback_parent_mission_id) ?? link?.callback) return true;
  if ((m?.tags ?? []).some(isDirectBtwTag) || link?.tags.some(isDirectBtwTag)) return true;
  return false;
};

function syncParentRowPlacement(id: string, project: string | null, folder: string, rev: number): void {
  const s = seen.get(id);
  if (s) {
    s.project = project;
    s.folder = folder;
  }
  const parentRow = parentRows.get(id);
  if (parentRow) {
    parentRows.set(id, {
      ...parentRow,
      project,
      folder,
      placement_revision: rev,
    });
    bumpResolver(v => v + 1);
  }
}

/** Apply `orbPlacementMergeStep` for a list/read row (`sourceKind = 0`) and return authoritative `(project, folder, placement_revision)`. */
function mergeIncomingPlacement(m: HierarchyFields, isPartial = false): PlacementState | undefined {
  const hasPlacement = m.project !== undefined || m.folder !== undefined || m.placement_revision !== undefined;
  if (!hasPlacement) {
    return placements.get(m.id);
  }
  const cur = placements.get(m.id);
  if (isPartial && m.placement_revision === undefined && cur) {
    return cur;
  }
  const incRev = typeof m.placement_revision === "number" && Number.isFinite(m.placement_revision) ? Math.max(0, Math.floor(m.placement_revision)) : 0;
  const hasParent = hasNestedParent(m.id, m);
  const incFolder = hasParent ? "" : normalizeMissionFolder(m.folder);
  const incProject = normalizeProject(m.project);
  if (!cur) {
    const state: PlacementState = {
      project: incProject,
      folder: incFolder,
      rev: incRev,
      pendingOpId: 0,
    };
    placements.set(m.id, state);
    return state;
  }
  const effectiveProject = m.project !== undefined ? incProject : cur.project;
  const effectiveFolder = hasParent ? "" : (m.folder !== undefined ? incFolder : cur.folder);
  const matchesOptimistic = cur.pendingOpId !== 0 && effectiveProject === cur.project && effectiveFolder === cur.folder;
  const verdict = orbPlacementMergeStep({
    curRev: cur.rev,
    incRev,
    pendingOpId: cur.pendingOpId,
    ackOpId: 0,
    sourceKind: 0,
    hasPlacement: true,
    matchesOptimistic,
  });
  if (!verdict.admitted) return cur;
  const nextState: PlacementState = {
    project: effectiveProject,
    folder: effectiveFolder,
    rev: Math.max(cur.rev, incRev, verdict.nextRev32),
    pendingOpId: verdict.clearPending ? 0 : cur.pendingOpId,
    rollback: verdict.clearPending ? undefined : cur.rollback,
  };
  placements.set(m.id, nextState);
  return nextState;
}

/** Stage an optimistic placement preview (`sourceKind = 2`) under `opId`. */
export function stageOptimisticPlacement(
  id: string,
  toProject: string | null,
  toFolder: string,
  opId: number,
  fallback?: { project?: string | null; folder?: string | null; placement_revision?: number },
): void {
  const cur = placements.get(id) ?? {
    project: normalizeProject(fallback?.project),
    folder: normalizeMissionFolder(fallback?.folder),
    rev: typeof fallback?.placement_revision === "number" ? fallback.placement_revision : 0,
    pendingOpId: 0,
  };
  const hasParent = hasNestedParent(id);
  const folder = hasParent ? "" : normalizeMissionFolder(toFolder);
  const proj = normalizeProject(toProject);
  const verdict = orbPlacementMergeStep({
    curRev: cur.rev,
    incRev: cur.rev,
    pendingOpId: cur.pendingOpId,
    ackOpId: opId,
    sourceKind: 2,
    hasPlacement: true,
    matchesOptimistic: false,
  });
  if (!verdict.admitted) return;
  placements.set(id, {
    project: proj,
    folder,
    rev: cur.rev,
    pendingOpId: opId,
    rollback: cur.rollback ?? { project: cur.project, folder: cur.folder, rev: cur.rev },
  });
  syncParentRowPlacement(id, proj, folder, cur.rev);
}

/** Roll back a failed or cancelled optimistic placement (`sourceKind = 3`) matching `ackOpId`. */
export function rollbackOptimisticPlacement(id: string, ackOpId: number): boolean {
  const cur = placements.get(id);
  if (!cur) return false;
  const verdict = orbPlacementMergeStep({
    curRev: cur.rev,
    incRev: cur.rev,
    pendingOpId: cur.pendingOpId,
    ackOpId,
    sourceKind: 3,
    hasPlacement: false,
    matchesOptimistic: false,
  });
  if (!verdict.admitted) return false;
  const prior = cur.rollback ?? { project: cur.project, folder: cur.folder, rev: cur.rev };
  placements.set(id, {
    project: prior.project,
    folder: prior.folder,
    rev: prior.rev,
    pendingOpId: 0,
  });
  syncParentRowPlacement(id, prior.project, prior.folder, prior.rev);
  return true;
}

/** Commit authoritative placement updates (`sourceKind = 1`) from `POST /api/control/missions/move` or `mission_placement_changed`. */
export function commitAuthoritativePlacements(items: readonly PlacementCommitInput[], ackOpId = 0): PlacementCommitItem[] {
  const accepted: PlacementCommitItem[] = [];
  for (const item of items) {
    if (!item || typeof item.mission_id !== "string") continue;
    const id = item.mission_id;
    const cur = placements.get(id);
    const incRev = typeof item.placement_revision === "number" && Number.isFinite(item.placement_revision)
      ? Math.max(0, Math.floor(item.placement_revision))
      : 0;
    const hasParent = hasNestedParent(id);
    const folder = hasParent ? "" : normalizeMissionFolder(item.folder);
    const proj = normalizeProject(item.project);
    const matchesOptimistic = !!(cur && cur.pendingOpId !== 0 && proj === cur.project && folder === cur.folder);
    const verdict = orbPlacementMergeStep({
      curRev: cur?.rev ?? 0,
      incRev,
      pendingOpId: cur?.pendingOpId ?? 0,
      ackOpId,
      sourceKind: 1 as PlacementSourceKind,
      hasPlacement: true,
      matchesOptimistic,
    });
    if (!verdict.admitted) continue;
    const nextPendingOpId = verdict.clearPending ? 0 : (cur?.pendingOpId ?? 0);
    placements.set(id, {
      project: proj,
      folder,
      rev: incRev,
      pendingOpId: nextPendingOpId,
      rollback: verdict.clearPending ? undefined : cur?.rollback,
    });
    syncParentRowPlacement(id, proj, folder, incRev);
    accepted.push({
      mission_id: id,
      project: proj,
      folder,
      placement_revision: incRev,
    });
  }
  return accepted;
}

/** Current authoritative placement known for `id` (if any). */
export function authoritativePlacement(id: string): Readonly<PlacementState> | undefined {
  return placements.get(id);
}

/** Tags that place a mission inside another one (or out of the root list). */
export const isHierarchyTag = (tag: string) =>
  tag.startsWith("worker-dispatch:") || tag === "superseded" || tag.startsWith("superseded_by:") ||
  tag.startsWith("superseded-by:") || tag.startsWith("fork-of:") || tag.startsWith("btw-parent:") ||
  tag === "btw-subagent";

const isDirectBtwTag = (tag: string) => tag.startsWith("btw-parent:") || tag === "btw-subagent";

type Link = { parent?: string; callback?: string; tags: string[] };
type Seen = { title?: string | null; project?: string | null; folder?: string; status?: string };

const links = new Map<string, Link>();
const seen = new Map<string, Seen>();
const parentOrds = new Map<string, number>();
const ordParents = new Map<number, string>();
let hierarchyEpoch = 0n;
const internParentOrd = (id: string | undefined): number => {
  if (!id) return 0;
  let ord = parentOrds.get(id);
  if (!ord) {
    ord = parentOrds.size + 1;
    parentOrds.set(id, ord);
    ordParents.set(ord, id);
  }
  return ord;
};
const isSupersededTag = (tag: string) =>
  tag === "superseded" || tag.startsWith("superseded_by:") || tag.startsWith("superseded-by:");
const nonEmpty = (v: string | null | undefined): string | undefined => (typeof v === "string" && v.trim() ? v : undefined);

/** Remember the links (and display facts) a payload carries. Never forgets. */
export function observeMission(m: HierarchyFields | null | undefined, isPartial = false): void {
  if (!m || typeof m.id !== "string") return;
  const parent = nonEmpty(m.parent_mission_id), callback = nonEmpty(m.callback_parent_mission_id);
  const tags = (m.tags ?? []).filter(isHierarchyTag);
  if (parent || callback || tags.length) {
    const link = links.get(m.id) ?? { tags: [] };
    // A non-empty value from a payload is authoritative; an absent one is not.
    if (parent) link.parent = parent;
    if (callback) link.callback = callback;
    for (const tag of tags) if (!link.tags.includes(tag)) link.tags.push(tag);
    links.set(m.id, link);
  }
  const s = seen.get(m.id) ?? {};
  if (m.title !== undefined && m.title !== null) s.title = m.title;
  seen.set(m.id, s);
  const authPlace = mergeIncomingPlacement(m, isPartial);
  if (authPlace) {
    s.project = authPlace.project;
    s.folder = authPlace.folder;
  } else if (m.project !== undefined) {
    s.project = m.project;
  }
  if (typeof m.status === "string" && m.status !== "unknown") s.status = m.status;
  seen.set(m.id, s);
}

/** The payload with every remembered link and authoritative placement restored. Same object when nothing was missing. */
export function withHierarchy<M extends HierarchyFields>(m: M): M {
  const link = links.get(m.id);
  const place = placements.get(m.id);
  if (!link && !place) return m;
  let out: M | undefined;
  const set = (key: keyof HierarchyFields, value: unknown) => { out ??= { ...m }; (out as Record<string, unknown>)[key] = value; };
  if (link) {
    if (link.parent && !nonEmpty(m.parent_mission_id)) set("parent_mission_id", link.parent);
    if (link.callback && !nonEmpty(m.callback_parent_mission_id)) set("callback_parent_mission_id", link.callback);
    if (link.tags.length) {
      const tags = m.tags ?? [];
      const missing = link.tags.filter(t => !tags.includes(t));
      if (missing.length) set("tags", [...tags, ...missing]);
    }
  }
  if (place) {
    const curProject = normalizeProject(m.project);
    if (curProject !== place.project) set("project", place.project);
    const curFolder = normalizeMissionFolder(m.folder);
    if (m.folder === undefined ? place.folder.length > 0 : curFolder !== place.folder) set("folder", place.folder);
    if ((m.placement_revision ?? 0) < place.rev) set("placement_revision", place.rev);
  }
  return out ?? m;
}

/** Observe then restore: what every network/journal boundary applies to its rows. */
export function stickHierarchy<M extends HierarchyFields>(m: M): M { observeMission(m); return withHierarchy(m); }

/**
 * The one mission merge. `next` is either a full row (a list or read answer:
 * it replaces `prev`, so cleared fields stay cleared) or a partial patch (a
 * stream status, an optimistic edit: only the fields it names change). Either
 * way the hierarchy links are never dropped.
 */
export function mergeMission<M extends HierarchyFields>(prev: M | undefined, next: Partial<M> & { id: string }, mode: "full" | "partial" = "full"): M {
  if (prev) observeMission(prev);
  observeMission(next as HierarchyFields, mode === "partial");
  const prevLink = links.get(next.id);
  const curParentOrd = internParentOrd(prevLink?.parent ?? nonEmpty(prev?.parent_mission_id));
  const incParent = nonEmpty(next.parent_mission_id);
  const incParentOrd = internParentOrd(incParent);
  const curSuperseded = !!(prevLink?.tags.some(isSupersededTag) || prev?.tags?.some(isSupersededTag));
  const incSupersede = curSuperseded || !!(next.tags?.some(isSupersededTag));
  const curArchived = curSuperseded || prev?.status === "completed" || prev?.status === "acknowledged";
  const incArchive = incSupersede || next.status === "completed" || next.status === "acknowledged";
  const incUnarchive = !incArchive && curArchived;
  const currentEpoch = hierarchyEpoch;
  hierarchyEpoch += 1n;
  const step = orbHierarchyMergeStep({
    currentEpoch,
    incomingEpoch: hierarchyEpoch,
    archiveEpoch: 0n,
    curArchived,
    curSuperseded,
    isPartialPatch: mode === "partial",
    parentPresence: incParent ? 1 : 0,
    curParentOrd,
    incParentOrd,
    incArchive,
    incUnarchive,
    incSupersede,
  });
  let merged: M;
  if (!step.admitted && prev) {
    merged = { ...prev };
  } else if (mode === "full" || !prev) {
    merged = next as M;
  } else {
    merged = { ...prev };
    for (const [key, value] of Object.entries(next)) if (value !== undefined) (merged as Record<string, unknown>)[key] = value;
  }
  return withHierarchy(merged);
}

/** Explicit re-parent (or `null` to detach): the only way a remembered link changes. */
export function reparentMission(id: string, fields: { parent_mission_id?: string | null; callback_parent_mission_id?: string | null }): void {
  const link = links.get(id) ?? { tags: [] };
  if ("parent_mission_id" in fields) {
    const incParent = nonEmpty(fields.parent_mission_id);
    const currentEpoch = hierarchyEpoch;
    hierarchyEpoch += 1n;
    const step = orbHierarchyMergeStep({
      currentEpoch,
      incomingEpoch: hierarchyEpoch,
      archiveEpoch: 0n,
      curArchived: false,
      curSuperseded: false,
      isPartialPatch: true,
      parentPresence: incParent ? 1 : 2,
      curParentOrd: internParentOrd(link.parent),
      incParentOrd: internParentOrd(incParent),
      incArchive: false,
      incUnarchive: false,
      incSupersede: false,
    });
    if (step.admitted) {
      link.parent = step.nextParentOrd ? ordParents.get(step.nextParentOrd) : undefined;
    }
  }
  if ("callback_parent_mission_id" in fields) link.callback = nonEmpty(fields.callback_parent_mission_id);
  links.set(id, link);
}

/** What the Orb last saw of a mission, for a placeholder row's label. */
export const seenMission = (id: string): Readonly<Seen> | undefined => seen.get(id);

export type BtwCandidate = {
  id?: string;
  parent_mission_id?: string | null;
  callback_parent_mission_id?: string | null;
  tags?: readonly string[] | null;
};

const directParentOf = (m: BtwCandidate): string | undefined => {
  const fork = m.tags?.find(t => t.startsWith("fork-of:"))?.slice(8);
  const p = nonEmpty(m.parent_mission_id);
  if (p && p !== fork) return p;
  return nonEmpty(m.callback_parent_mission_id);
};

/** Main conversation ID when `m` is itself a `/btw` side session (`btw-parent:<id>`). */
export function btwParentId(m: { id?: string; tags?: readonly string[] | null } | null | undefined): string | undefined {
  if (!m) return undefined;
  const direct = m.tags?.find(t => t.startsWith("btw-parent:"))?.slice("btw-parent:".length);
  if (direct) return direct;
  return m.id ? links.get(m.id)?.tags.find(t => t.startsWith("btw-parent:"))?.slice("btw-parent:".length) : undefined;
}

/** True when `m` is a `/btw` side session or any worker/descendant in its subtree. */
export function isBtwMission(
  m: BtwCandidate | null | undefined,
  byId?: ReadonlyMap<string, BtwCandidate>,
): boolean {
  if (!m) return false;
  if (m.tags?.some(isDirectBtwTag)) return true;
  const seenIds = new Set<string>();
  if (m.id) {
    if (links.get(m.id)?.tags.some(isDirectBtwTag)) return true;
    seenIds.add(m.id);
  }
  const link0 = m.id ? links.get(m.id) : undefined;
  let cur = directParentOf(m) ?? link0?.parent ?? link0?.callback;
  while (cur && !seenIds.has(cur)) {
    seenIds.add(cur);
    const row = byId?.get(cur);
    const link = links.get(cur);
    if (row?.tags?.some(isDirectBtwTag) || link?.tags.some(isDirectBtwTag)) return true;
    cur = (row ? directParentOf(row) : undefined) ?? link?.parent ?? link?.callback;
  }
  return false;
}

/** Pure batch filter excluding `/btw` side sessions and their descendants regardless of row order. */
export function excludeBtwMissions<M extends HierarchyFields>(rows: readonly M[]): M[] {
  const byId = new Map<string, HierarchyFields>();
  for (const row of rows) if (row && typeof row.id === "string") byId.set(row.id, row);
  return rows.filter(row => !isBtwMission(row, byId));
}

// ---------------------------------------------------------------------------
// Parent resolver: a child whose parent is not loaded is held under a
// placeholder while the parent is fetched by id. Only a parent confirmed gone
// (404) lets the child fall back to the root.

export type ParentState = "loading" | "found" | "gone";
const parentState = new Map<string, ParentState>();
const parentRows = new Map<string, HierarchyFields>();
const retries = new Map<string, number>();
const [resolverVersion, bumpResolver] = createSignal(0);
let fetcher: ((id: string) => Promise<HierarchyFields | null>) | undefined;
let timer: (fn: () => void, ms: number) => void = (fn, ms) => { setTimeout(fn, ms); };

/** Wire the fetch (and, in tests, a clock). A fetch resolves null only for 404. */
export function configureParentResolver(fetch: (id: string) => Promise<HierarchyFields | null>, schedule?: (fn: () => void, ms: number) => void): void {
  fetcher = fetch;
  if (schedule) timer = schedule;
}

/** Ask for a parent. Returns its current state; tracks `resolverVersion` for reactivity. */
export function resolveParent(id: string): ParentState {
  resolverVersion();
  if (isBtwMission({ id })) return "gone";
  const state = parentState.get(id);
  if (state) return state;
  parentState.set(id, "loading");
  const attempt = () => {
    if (!fetcher) return;
    fetcher(id).then(row => {
      if (row) {
        observeMission(row);
        if (isBtwMission(row)) {
          parentRows.delete(id);
          parentState.set(id, "gone");
        } else {
          parentRows.set(id, withHierarchy(row));
          parentState.set(id, "found");
        }
      }
      else parentState.set(id, "gone");
      bumpResolver(v => v + 1);
    }, () => {
      // Transient: keep the placeholder and retry with backoff (1s … 30s).
      const n = (retries.get(id) ?? 0) + 1;
      retries.set(id, n);
      timer(attempt, Math.min(30_000, 1000 * 2 ** (n - 1)));
    });
  };
  queueMicrotask(attempt);
  return "loading";
}

/** Track reactive parent-resolution updates (e.g. when a missing parent resolves as `/btw`). */
export function trackHierarchyResolution(): void {
  resolverVersion();
}

/** A parent the resolver fetched, for listing as context next to its children. */
export function resolvedParent<M extends HierarchyFields>(id: string): M | undefined {
  resolverVersion();
  const row = parentRows.get(id) as M | undefined;
  return row && !isBtwMission(row) ? row : undefined;
}
/** Every parent the resolver has fetched. */
export function resolvedParents<M extends HierarchyFields>(): M[] {
  resolverVersion();
  return excludeBtwMissions([...parentRows.values()] as M[]);
}

/** A parent is known to be gone; seen as a list row again it is back. */
export function markParentSeen(id: string): void {
  if (parentState.get(id) === "gone") { parentState.delete(id); bumpResolver(v => v + 1); }
}

/** Tests and connection switches start from nothing. */
export function resetMissionHierarchy(): void {
  links.clear(); seen.clear(); placements.clear(); nextClientOpId = 0;
  parentOrds.clear(); ordParents.clear(); hierarchyEpoch = 0n;
  parentState.clear(); parentRows.clear(); retries.clear();
  bumpResolver(v => v + 1);
}

// ---------------------------------------------------------------------------
// List reconciliation: a failed, empty or partial answer never removes rows.

/** Marks a list that is known to be incomplete (e.g. Core unreachable, only the desktop journal answered). */
export const PARTIAL = Symbol("partial mission list");
export type MaybePartial<T> = T[] & { [PARTIAL]?: true };
export const partialList = <T,>(rows: T[]): MaybePartial<T> => Object.defineProperty(rows, PARTIAL, { value: true, enumerable: false }) as MaybePartial<T>;
export const isPartialList = (rows: unknown): boolean => !!(rows as MaybePartial<unknown>)?.[PARTIAL];

/** How many consecutive authoritative lists must omit a row before it is dropped… */
export const MISSES_TO_REMOVE = 2;
/** …spread over at least this long: one poll can trigger several reads of the same list. */
export const MISS_WINDOW_MS = 5000;
export type Misses = Map<string, { n: number; since: number }>;

/**
 * Reconcile a fresh list into the rows on screen. Every fresh row goes through
 * `mergeMission`. A row missing from the answer is kept: always when the answer
 * is partial, otherwise until `MISSES_TO_REMOVE` consecutive full answers spread
 * over `MISS_WINDOW_MS` omit it (a list served while Core or Hermes restarts can
 * be empty or short). Explicit deletes and archives remove rows directly.
 */
export function reconcileMissionList<M extends HierarchyFields>(prev: readonly M[], next: readonly M[], misses: Misses, partial = isPartialList(next), now = Date.now()): M[] {
  const prevById = new Map(prev.map(m => [m.id, m]));
  const fresh = new Set(next.map(m => m.id));
  const out: M[] = next.map(m => {
    misses.delete(m.id);
    markParentSeen(m.id);
    const old = prevById.get(m.id);
    const merged = mergeMission(old, m);
    return old && shallowEqual(old, merged) ? old : merged;
  });
  for (const m of prev) {
    if (fresh.has(m.id)) continue;
    const miss = misses.get(m.id) ?? { n: 0, since: now };
    if (!partial) miss.n++;
    if (miss.n >= MISSES_TO_REMOVE && now - miss.since >= MISS_WINDOW_MS) { misses.delete(m.id); continue; }
    misses.set(m.id, miss);
    out.push(m);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Open missions beyond the history page (sidebar-hierarchy.md, M2).

/** Running or waiting on the user: always worth showing, however old. */
export const LIVE_OPEN = new Set(["active", "running", "pending", "queued", "awaiting_user", "resuming", "starting", "waiting_background"]);
/** Stopped but maybe still wanted: shown beyond the page only while recent. */
export const RECENT_OPEN = new Set(["interrupted", "failed", "paused", "blocked"]);
export const RECENT_OPEN_MS = 7 * 24 * 60 * 60 * 1000;

type OpenRow = HierarchyFields & { status: string; updated_at?: string | null; created_at?: string | null };
/**
 * Which open missions older than the history page are added to it. Live ones
 * always; interrupted/failed/paused/blocked ones only if updated in the last
 * `RECENT_OPEN_MS` (older ones are history, left to the archive). A child is
 * added only if it is live itself (its parent is then fetched) or if its
 * parent is already listed: a stale child never brings in, or stands in for,
 * a finished parent.
 */
export function openBeyondPage<M extends OpenRow>(history: readonly M[], extra: readonly M[], now = Date.now()): M[] {
  const byId = new Map<string, OpenRow>();
  for (const m of history) byId.set(m.id, m);
  for (const m of extra) if (!byId.has(m.id)) byId.set(m.id, m);
  const listed = new Set(history.map(m => m.id));
  const at = (m: M) => Date.parse(m.updated_at || m.created_at || "") || 0;
  const wanted = extra.filter(m => !listed.has(m.id) && !isBtwMission(m, byId) && (LIVE_OPEN.has(m.status) || (RECENT_OPEN.has(m.status) && now - at(m) <= RECENT_OPEN_MS)));
  const ids = new Set([...listed, ...wanted.map(m => m.id)]);
  const parentOf = (m: M) => nonEmpty(m.parent_mission_id) ?? nonEmpty(m.callback_parent_mission_id);
  return wanted.filter(m => { const p = parentOf(m); return !p || LIVE_OPEN.has(m.status) || ids.has(p); });
}
