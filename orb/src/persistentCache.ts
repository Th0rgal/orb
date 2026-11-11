// Persistent cache (`orb-locald` native `~/.orb/ui-cache` on Desktop, IndexedDB `orb-cache-v1`
// on Web) for instant (< 5 ms) cold-start and offline sidebar + transcript rendering.
// - Scoped strictly by normalized `apiUrl` + auth token hash (`historyScope()`).
// - LRU-bounded at `MAX_PERSISTED_TRANSCRIPTS = 24` ready transcripts.
// - Wiped immediately on `clearConnection()` so sign-out/disconnect leaves zero residual data.
// - Uses `orb-locald` (`ui_cache_*`) on Desktop to eliminate WebKit IndexedDB structured-clone stalls,
//   falling back seamlessly to IndexedDB or bounded in-memory mirror on Web / unit tests.

import { nativeInvoke, type NativeInvoke } from "./native";

const DB_NAME = "orb-cache-v1";
const DB_VERSION = 1;
const STORE_SIDEBAR = "sidebar";
const STORE_TRANSCRIPTS = "transcripts";
export const MAX_PERSISTED_TRANSCRIPTS = 24;

export type PersistedSidebarPayload<TMission = unknown, TProject = unknown> = {
  scope: string;
  savedAt: number;
  missions: TMission[];
  completedMissions: TMission[];
  projects: TProject[];
};

export type PersistedTranscriptRecord<TSnap = unknown> = {
  id: string;
  scope: string;
  missionId: string;
  savedAt: number;
  snapshot: TSnap;
};

const memSidebar = new Map<string, PersistedSidebarPayload>();
const memTranscripts = new Map<string, PersistedTranscriptRecord>();
let knownDbTranscriptIds: Set<string> | null = null;
let dbPromise: Promise<IDBDatabase | null> | null = null;
let unsupportedInvoke: NativeInvoke | null = null;

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
    return Promise.resolve(null);
  }
  if (dbPromise) return dbPromise;
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

function evictMemoryTranscripts(): void {
  if (memTranscripts.size <= MAX_PERSISTED_TRANSCRIPTS) return;
  const sorted = [...memTranscripts.values()].sort((a, b) => a.savedAt - b.savedAt);
  const excess = memTranscripts.size - MAX_PERSISTED_TRANSCRIPTS;
  for (let i = 0; i < excess; i++) {
    memTranscripts.delete(sorted[i].id);
  }
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
  },
): Promise<void> {
  if (!scope) return;
  const record: PersistedSidebarPayload<TMission, TProject> = {
    scope,
    savedAt: Date.now(),
    missions: payload.missions,
    completedMissions: payload.completedMissions ?? [],
    projects: payload.projects,
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
    memHit.savedAt = Date.now();
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
    savedAt: Date.now(),
    snapshot,
  };
  memTranscripts.set(id, record);
  evictMemoryTranscripts();
  const invoke = activeLocaldCache();
  if (invoke) {
    try {
      await invoke("ui_cache_put", {
        kind: "transcript",
        key: id,
        saved_at: record.savedAt,
        raw: JSON.stringify(record),
      });
      return;
    } catch (err) {
      if (isUnsupportedCacheCommandError(err)) {
        unsupportedInvoke = invoke;
      } else {
        await invoke("ui_cache_put", {
          kind: "transcript",
          key: id,
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
      const tx = db.transaction(STORE_TRANSCRIPTS, "readwrite");
      const store = tx.objectStore(STORE_TRANSCRIPTS);
      store.put(record);
      const needsSweep =
        knownDbTranscriptIds === null ||
        (!knownDbTranscriptIds.has(id) && knownDbTranscriptIds.size >= MAX_PERSISTED_TRANSCRIPTS);
      if (!needsSweep && knownDbTranscriptIds) {
        knownDbTranscriptIds.add(id);
      } else {
        const allReq = store.index("by_saved_at").getAllKeys();
        allReq.onsuccess = () => {
          const keys = allReq.result;
          if (Array.isArray(keys)) {
            const nextIds = new Set(keys.map(String));
            nextIds.add(id);
            if (keys.length > MAX_PERSISTED_TRANSCRIPTS) {
              const dropCount = keys.length - MAX_PERSISTED_TRANSCRIPTS;
              for (let i = 0; i < dropCount; i++) {
                store.delete(keys[i]);
                nextIds.delete(String(keys[i]));
              }
            }
            knownDbTranscriptIds = nextIds;
          }
        };
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
  memSidebar.clear();
  memTranscripts.clear();
  knownDbTranscriptIds = null;
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
  memSidebar.clear();
  memTranscripts.clear();
  knownDbTranscriptIds = null;
  unsupportedInvoke = null;
}
