// Persistent cache (`orb-locald` native `~/.orb/ui-cache` on Desktop, IndexedDB `orb-cache-v1`
// on Web) for instant (< 5 ms) cold-start and offline sidebar + transcript rendering.
// - Scoped strictly by normalized `apiUrl` + auth token hash (`historyScope()`).
// - Two-tier LRU-bounded at `MAX_PERSISTED_TRANSCRIPTS = 250` ready transcripts:
//   - Hot tier (`HOT_PERSISTED_TRANSCRIPTS = 32`): full settled `StreamItem[]` + recent raw tail.
//   - Warm tier (`33..250`): compact conversational spine (prompts + received answers + work counts).
// - Wiped immediately on `clearConnection()` so sign-out/disconnect leaves zero residual data.
// - Uses `orb-locald` (`ui_cache_*`) on Desktop to eliminate WebKit IndexedDB structured-clone stalls,
//   falling back seamlessly to IndexedDB or bounded in-memory mirror on Web / unit tests.

import { nativeInvoke, type NativeInvoke } from "./native";

const DB_NAME = "orb-cache-v1";
const DB_VERSION = 1;
const STORE_SIDEBAR = "sidebar";
const STORE_TRANSCRIPTS = "transcripts";
export const HOT_PERSISTED_TRANSCRIPTS = 32;
export const MAX_PERSISTED_TRANSCRIPTS = 250;

export type PersistedSidebarPayload<TMission = unknown, TProject = unknown> = {
  scope: string;
  savedAt: number;
  missions: TMission[];
  completedMissions: TMission[];
  projects: TProject[];
  projectMissions?: Record<string, TMission[]>;
};

export type PersistedTranscriptRecord<TSnap = unknown> = {
  id: string;
  scope: string;
  missionId: string;
  savedAt: number;
  tier?: "hot" | "warm";
  snapshot: TSnap;
};

/** Compact a full transcript snapshot into a lightweight warm-tier spine digest
 * (retaining user prompts, received assistant answers, errors, and pre-digested
 * settled turn items with collapsed work-group counts while shedding raw tool blobs).
 * Non-transcript test payloads pass through untouched. */
export function compactWarmTranscriptSnapshot<TSnap>(snapshot: TSnap): TSnap {
  if (!snapshot || typeof snapshot !== "object") return snapshot;
  const rec = snapshot as Record<string, unknown>;
  if (!Array.isArray(rec.stream) || !Array.isArray(rec.items)) return snapshot;
  const spineStream = (rec.stream as Array<Record<string, unknown>>).filter((ev) => {
    const t = ev?.type;
    return (
      t === "user_message" ||
      t === "assistant_message" ||
      t === "assistant_message_canonical" ||
      t === "error" ||
      t === "mission_status_changed"
    );
  });
  const compactSingleItem = (it: Record<string, unknown>): Record<string, unknown> => {
    if (!it || typeof it !== "object") return it;
    if (it.kind === "tool") {
      const shortRes =
        typeof it.result === "string" && it.result.length > 160
          ? it.result.slice(0, 160)
          : it.result && typeof it.result === "object"
            ? undefined
            : it.result;
      const shortArgs =
        typeof it.args === "string" && it.args.length > 160
          ? it.args.slice(0, 160)
          : undefined;
      return {
        ...it,
        ...(shortArgs !== undefined ? { args: shortArgs } : { args: {} }),
        ...(shortRes !== undefined ? { result: shortRes } : { result: undefined }),
        truncated: true,
      };
    }
    if (it.kind === "think" && typeof it.text === "string" && it.text.length > 160) {
      return { ...it, text: it.text.slice(0, 160) };
    }
    if (it.kind === "work" && Array.isArray(it.entries) && it.entries.length > 0) {
      const strippedEntries = (it.entries as Array<Record<string, unknown>>).map((entry) => {
        if (entry?.kind === "tool") {
          return {
            ...entry,
            ...(typeof entry.result === "string" && entry.result.length > 256
              ? { result: entry.result.slice(0, 256), truncated: true }
              : {}),
          };
        }
        return entry;
      });
      return { ...it, entries: strippedEntries };
    }
    return it;
  };
  const rawItems = rec.items as Array<Record<string, unknown>>;
  const compactItems = rawItems.map(compactSingleItem);
  const compactSettled =
    rawItems.length === 0 && Array.isArray(rec.settledItems)
      ? (rec.settledItems as Array<Record<string, unknown>>).map(compactSingleItem)
      : undefined;
  const activityCompacted = spineStream.length < (rec.stream as unknown[]).length;
  return {
    ...rec,
    items: compactItems,
    settledItems: compactSettled,
    stream: spineStream,
    openTailEvents: undefined,
    liveTail: undefined,
    ...(activityCompacted
      ? {
          activityCompacted: true,
          cursor: undefined,
          before: undefined,
          spineComplete: false,
          hasOlder: true,
        }
      : {
          spineComplete: false,
          hasOlder: rec.hasOlder === true,
        }),
  } as TSnap;
}

const memSidebar = new Map<string, PersistedSidebarPayload>();
const memTranscripts = new Map<string, PersistedTranscriptRecord>();
let knownDbTranscriptIds: Set<string> | null = null;
let knownDbHotTranscriptIds: Set<string> | null = null;
let dbPromise: Promise<IDBDatabase | null> | null = null;
let dbSource: IDBFactory | null = null;
let lastSavedStamp = 0;
let nativeCacheGeneration = 0;
let unsupportedInvoke: NativeInvoke | null = null;

function nextSavedAt(): number {
  const now = Date.now();
  lastSavedStamp = now > lastSavedStamp ? now : lastSavedStamp + 1;
  return lastSavedStamp;
}

function isUnsupportedCacheCommandError(err: unknown): boolean {
  const msg = String((err as Error)?.message ?? err ?? "");
  return /unknown desktop command|is not supported in this local runtime/i.test(msg);
}

function activeLocaldCache(): NativeInvoke | null {
  const invoke = nativeInvoke();
  if (!invoke || invoke === unsupportedInvoke) return null;
  return invoke;
}

function openDb(): Promise<IDBDatabase | null> {
  if (typeof indexedDB === "undefined" || !indexedDB) {
    dbPromise = null;
    dbSource = null;
    return Promise.resolve(null);
  }
  if (dbPromise && dbSource === indexedDB) return dbPromise;
  dbSource = indexedDB;
  knownDbTranscriptIds = null;
  knownDbHotTranscriptIds = null;
  dbPromise = new Promise<IDBDatabase | null>((resolve) => {
    try {
      const req = indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains(STORE_SIDEBAR)) {
          db.createObjectStore(STORE_SIDEBAR, { keyPath: "scope" });
        }
        if (!db.objectStoreNames.contains(STORE_TRANSCRIPTS)) {
          const store = db.createObjectStore(STORE_TRANSCRIPTS, { keyPath: "id" });
          store.createIndex("by_saved_at", "savedAt", { unique: false });
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
      req.onblocked = () => resolve(null);
    } catch {
      resolve(null);
    }
  });
  return dbPromise;
}

function transcriptRecordKey(scope: string, missionId: string): string {
  return `${scope}::m:${missionId}`;
}

function evictMemoryTranscripts(): PersistedTranscriptRecord[] {
  if (memTranscripts.size <= HOT_PERSISTED_TRANSCRIPTS) return [];
  const sorted = [...memTranscripts.values()].sort((a, b) => a.savedAt - b.savedAt);
  if (memTranscripts.size > MAX_PERSISTED_TRANSCRIPTS) {
    const excess = memTranscripts.size - MAX_PERSISTED_TRANSCRIPTS;
    for (let i = 0; i < excess; i++) {
      memTranscripts.delete(sorted[i].id);
    }
    sorted.splice(0, excess);
  }
  const warmCutoff = sorted.length - HOT_PERSISTED_TRANSCRIPTS;
  const demoted: PersistedTranscriptRecord[] = [];
  for (let i = 0; i < warmCutoff; i++) {
    const rec = sorted[i];
    if (rec.tier !== "warm") {
      rec.snapshot = compactWarmTranscriptSnapshot(rec.snapshot);
      rec.tier = "warm";
      demoted.push(rec);
    }
  }
  return demoted;
}

export async function loadPersistedSidebar<TMission = unknown, TProject = unknown>(
  scope: string,
): Promise<PersistedSidebarPayload<TMission, TProject> | null> {
  if (!scope) return null;
  const memHit = memSidebar.get(scope) as PersistedSidebarPayload<TMission, TProject> | undefined;
  if (memHit) return memHit;
  const invoke = activeLocaldCache();
  if (invoke) {
    try {
      const raw = await invoke<string | null>("ui_cache_get", { kind: "sidebar", key: scope });
      if (typeof raw === "string" && raw) {
        const row = JSON.parse(raw) as PersistedSidebarPayload<TMission, TProject>;
        if (row && Array.isArray(row.missions) && Array.isArray(row.projects)) {
          memSidebar.set(scope, row);
          return row;
        }
      }
    } catch (err) {
      if (isUnsupportedCacheCommandError(err)) unsupportedInvoke = invoke;
    }
  }
  const db = await openDb();
  if (!db) return null;
  return new Promise((resolve) => {
    try {
      const tx = db.transaction(STORE_SIDEBAR, "readonly");
      const req = tx.objectStore(STORE_SIDEBAR).get(scope);
      req.onsuccess = () => {
        const row = req.result as PersistedSidebarPayload<TMission, TProject> | undefined;
        if (row && Array.isArray(row.missions) && Array.isArray(row.projects)) {
          memSidebar.set(scope, row);
          resolve(row);
        } else {
          resolve(null);
        }
      };
      req.onerror = () => resolve(null);
    } catch {
      resolve(null);
    }
  });
}

export async function savePersistedSidebar<TMission = unknown, TProject = unknown>(
  scope: string,
  payload: {
    missions: TMission[];
    completedMissions?: TMission[];
    projects: TProject[];
    projectMissions?: Record<string, TMission[]>;
  },
): Promise<void> {
  if (!scope) return;
  const prev = memSidebar.get(scope) as PersistedSidebarPayload<TMission, TProject> | undefined;
  const record: PersistedSidebarPayload<TMission, TProject> = {
    scope,
    savedAt: Date.now(),
    missions: payload.missions,
    completedMissions: payload.completedMissions ?? prev?.completedMissions ?? [],
    projects: payload.projects,
    projectMissions: payload.projectMissions ?? prev?.projectMissions,
  };
  memSidebar.set(scope, record);
  const invoke = activeLocaldCache();
  if (invoke) {
    try {
      await invoke("ui_cache_put", {
        kind: "sidebar",
        key: scope,
        saved_at: record.savedAt,
        raw: JSON.stringify(record),
      });
      return;
    } catch (err) {
      if (isUnsupportedCacheCommandError(err)) {
        unsupportedInvoke = invoke;
      } else {
        await invoke("ui_cache_put", {
          kind: "sidebar",
          key: scope,
          saved_at: record.savedAt,
          raw: "{}",
        }).catch(() => undefined);
      }
    }
  }
  const db = await openDb();
  if (!db) return;
  await new Promise<void>((resolve) => {
    try {
      const tx = db.transaction(STORE_SIDEBAR, "readwrite");
      tx.objectStore(STORE_SIDEBAR).put(record);
      tx.oncomplete = () => resolve();
      tx.onerror = () => resolve();
      tx.onabort = () => resolve();
    } catch {
      resolve();
    }
  });
}

export async function loadPersistedTranscript<TSnap = unknown>(
  scope: string,
  missionId: string,
): Promise<TSnap | null> {
  if (!scope || !missionId) return null;
  const id = transcriptRecordKey(scope, missionId);
  const memHit = memTranscripts.get(id);
  if (memHit) {
    memHit.savedAt = nextSavedAt();
    return memHit.snapshot as TSnap;
  }
  const invoke = activeLocaldCache();
  if (invoke) {
    try {
      const raw = await invoke<string | null>("ui_cache_get", { kind: "transcript", key: id });
      if (typeof raw === "string" && raw) {
        const row = JSON.parse(raw) as PersistedTranscriptRecord<TSnap>;
        if (row && row.snapshot) {
          memTranscripts.set(id, row);
          evictMemoryTranscripts();
          return row.snapshot;
        }
      }
    } catch (err) {
      if (isUnsupportedCacheCommandError(err)) unsupportedInvoke = invoke;
    }
  }
  const db = await openDb();
  if (!db) return null;
  return new Promise((resolve) => {
    try {
      const tx = db.transaction(STORE_TRANSCRIPTS, "readonly");
      const req = tx.objectStore(STORE_TRANSCRIPTS).get(id);
      req.onsuccess = () => {
        const row = req.result as PersistedTranscriptRecord<TSnap> | undefined;
        if (row && row.snapshot) {
          memTranscripts.set(id, row);
          evictMemoryTranscripts();
          resolve(row.snapshot);
        } else {
          resolve(null);
        }
      };
      req.onerror = () => resolve(null);
    } catch {
      resolve(null);
    }
  });
}

export async function savePersistedTranscript<TSnap = unknown>(
  scope: string,
  missionId: string,
  snapshot: TSnap,
): Promise<void> {
  if (!scope || !missionId) return;
  const id = transcriptRecordKey(scope, missionId);
  const record: PersistedTranscriptRecord<TSnap> = {
    id,
    scope,
    missionId,
    savedAt: nextSavedAt(),
    tier: "hot",
    snapshot,
  };
  memTranscripts.set(id, record);
  const demoted = evictMemoryTranscripts();
  const invoke = activeLocaldCache();
  if (invoke) {
    const gen = nativeCacheGeneration;
    try {
      const putRes = await invoke<{ demote_keys?: string[] } | null>("ui_cache_put", {
        kind: "transcript",
        key: id,
        saved_at: record.savedAt,
        tier: record.tier ?? "hot",
        raw: JSON.stringify(record),
      });
      if (gen !== nativeCacheGeneration) return;
      const handledKeys = new Set<string>();
      for (const warmRec of demoted) {
        handledKeys.add(warmRec.id);
        await invoke("ui_cache_put", {
          kind: "transcript",
          key: warmRec.id,
          saved_at: warmRec.savedAt,
          tier: "warm",
          raw: JSON.stringify(warmRec),
        }).catch(() => undefined);
        if (gen !== nativeCacheGeneration) return;
      }
      const diskDemoteKeys = Array.isArray(putRes?.demote_keys) ? putRes.demote_keys : [];
      for (const dKey of diskDemoteKeys) {
        if (!dKey || handledKeys.has(dKey) || dKey === id) continue;
        if (gen !== nativeCacheGeneration) return;
        const memRow = memTranscripts.get(dKey);
        if (memRow && memRow.savedAt > record.savedAt) continue;
        const diskRaw = await invoke<string | null>("ui_cache_get", { kind: "transcript", key: dKey }).catch(() => null);
        if (gen !== nativeCacheGeneration || typeof diskRaw !== "string" || !diskRaw) continue;
        try {
          const parsed = JSON.parse(diskRaw) as PersistedTranscriptRecord;
          if (!parsed || !parsed.snapshot) continue;
          const liveMem = memTranscripts.get(dKey);
          if (liveMem && liveMem.savedAt > (parsed.savedAt ?? 0)) continue;
          const warmRec: PersistedTranscriptRecord = {
            ...parsed,
            tier: "warm",
            snapshot: compactWarmTranscriptSnapshot(parsed.snapshot),
          };
          if (liveMem && liveMem.savedAt === parsed.savedAt) {
            memTranscripts.set(dKey, warmRec);
          }
          await invoke("ui_cache_put", {
            kind: "transcript",
            key: dKey,
            saved_at: warmRec.savedAt,
            tier: "warm",
            raw: JSON.stringify(warmRec),
          }).catch(() => undefined);
        } catch {
          /* ignore malformed disk cache entry */
        }
      }
      return;
    } catch (err) {
      if (isUnsupportedCacheCommandError(err)) {
        unsupportedInvoke = invoke;
      } else if (gen === nativeCacheGeneration) {
        await invoke("ui_cache_put", {
          kind: "transcript",
          key: id,
          saved_at: record.savedAt,
          tier: "warm",
          raw: "{}",
        }).catch(() => undefined);
      }
    }
  }
  const db = await openDb();
  if (!db) return;
  await new Promise<void>((resolve) => {
    try {
      const tx = db.transaction(STORE_TRANSCRIPTS, "readwrite");
      const store = tx.objectStore(STORE_TRANSCRIPTS);
      store.put(record);
      const needsSweep =
        knownDbTranscriptIds === null ||
        knownDbHotTranscriptIds === null ||
        (!knownDbHotTranscriptIds.has(id) && knownDbHotTranscriptIds.size >= HOT_PERSISTED_TRANSCRIPTS) ||
        (!knownDbTranscriptIds.has(id) && knownDbTranscriptIds.size >= MAX_PERSISTED_TRANSCRIPTS);
      if (!needsSweep && knownDbTranscriptIds && knownDbHotTranscriptIds) {
        knownDbTranscriptIds.add(id);
        knownDbHotTranscriptIds.add(id);
      } else {
        const idx = store.index("by_saved_at") as IDBIndex & { getAll?: () => IDBRequest };
        if (typeof idx.getAll === "function") {
          const allReq = idx.getAll();
          allReq.onsuccess = () => {
            const rawRows = allReq.result as PersistedTranscriptRecord[] | undefined;
            if (!Array.isArray(rawRows)) return;
            const rows = [...rawRows].sort((a, b) => a.savedAt - b.savedAt);
            const nextIds = new Set(rows.map((r) => String(r.id)));
            nextIds.add(id);
            let remaining = rows;
            if (rows.length > MAX_PERSISTED_TRANSCRIPTS) {
              const dropCount = rows.length - MAX_PERSISTED_TRANSCRIPTS;
              for (let i = 0; i < dropCount; i++) {
                store.delete(rows[i].id);
                nextIds.delete(String(rows[i].id));
              }
              remaining = rows.slice(dropCount);
            }
            const hotStart = Math.max(0, remaining.length - HOT_PERSISTED_TRANSCRIPTS);
            if (hotStart > 0) {
              for (let i = 0; i < hotStart; i++) {
                const r = remaining[i];
                if (r.tier !== "warm") {
                  store.put({
                    ...r,
                    tier: "warm",
                    snapshot: compactWarmTranscriptSnapshot(r.snapshot),
                  });
                }
              }
            }
            knownDbTranscriptIds = nextIds;
            knownDbHotTranscriptIds = new Set(
              remaining.slice(hotStart).map((r) => String(r.id)),
            );
          };
        } else if (typeof idx.getAllKeys === "function") {
          const keysReq = idx.getAllKeys();
          keysReq.onsuccess = () => {
            const keys = (keysReq.result as IDBValidKey[] | undefined) ?? [];
            const nextIds = new Set(keys.map((k) => String(k)));
            nextIds.add(id);
            if (keys.length > MAX_PERSISTED_TRANSCRIPTS) {
              const dropCount = keys.length - MAX_PERSISTED_TRANSCRIPTS;
              for (let i = 0; i < dropCount; i++) {
                store.delete(keys[i]!);
                nextIds.delete(String(keys[i]));
              }
            }
            knownDbTranscriptIds = nextIds;
            knownDbHotTranscriptIds = nextIds;
          };
        }
      }
      tx.oncomplete = () => resolve();
      tx.onerror = () => resolve();
      tx.onabort = () => resolve();
    } catch {
      resolve();
    }
  });
}

export async function clearPersistentCache(): Promise<void> {
  nativeCacheGeneration += 1;
  memSidebar.clear();
  memTranscripts.clear();
  knownDbTranscriptIds = null;
  knownDbHotTranscriptIds = null;
  lastSavedStamp = 0;
  const invoke = nativeInvoke();
  if (invoke) {
    try {
      await invoke("ui_cache_clear", {});
    } catch (err) {
      if (isUnsupportedCacheCommandError(err)) unsupportedInvoke = invoke;
    }
  }
  const db = await openDb();
  if (!db) return;
  await new Promise<void>((resolve) => {
    try {
      const tx = db.transaction([STORE_SIDEBAR, STORE_TRANSCRIPTS], "readwrite");
      tx.objectStore(STORE_SIDEBAR).clear();
      tx.objectStore(STORE_TRANSCRIPTS).clear();
      tx.oncomplete = () => resolve();
      tx.onerror = () => resolve();
      tx.onabort = () => resolve();
    } catch {
      resolve();
    }
  });
}

export function resetPersistentCacheMemoryForTest(): void {
  nativeCacheGeneration += 1;
  memSidebar.clear();
  memTranscripts.clear();
  knownDbTranscriptIds = null;
  knownDbHotTranscriptIds = null;
  lastSavedStamp = 0;
  unsupportedInvoke = null;
}
