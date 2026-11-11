import type { DraftImage } from "./imageAttachments";
import { nativeInvoke, type NativeInvoke } from "./native";
import type { UploadedFile } from "./uploads";

export interface ComposerDraft {
  mode?: "goal" | "plan" | "btw" | null;
  text: string;
  images: DraftImage[];
  uploads?: UploadedFile[];
}

let database: Promise<IDBDatabase> | undefined;
let unsupportedDraftInvoke: NativeInvoke | null = null;
// Closing and reopening a composer can beat disk writes. Keep the latest write
// visible synchronously, including while an older disk read is in flight.
const currentDrafts = new Map<string, ComposerDraft>();
const sideThreadLocks = new Map<string, Promise<void>>();

function isUnsupportedDraftCommandError(err: unknown): boolean {
  const msg = String((err as Error)?.message ?? err ?? "");
  return /unknown desktop command|is not supported in this local runtime/i.test(msg);
}

function activeLocaldDrafts(): NativeInvoke | null {
  const invoke = nativeInvoke();
  if (!invoke || invoke === unsupportedDraftInvoke) return null;
  return invoke;
}

function hasNonJsonBinaryInstance(value: unknown, seen = new Set<unknown>()): boolean {
  if (!value || typeof value !== "object") return false;
  if (typeof Blob !== "undefined" && value instanceof Blob) return true;
  if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return true;
  if (seen.has(value)) return false;
  seen.add(value);
  if (Array.isArray(value)) {
    return value.some((item) => hasNonJsonBinaryInstance(item, seen));
  }
  for (const val of Object.values(value as Record<string, unknown>)) {
    if (hasNonJsonBinaryInstance(val, seen)) return true;
  }
  return false;
}

function db(): Promise<IDBDatabase> {
  return (database ??= new Promise((resolve, reject) => {
    const request = indexedDB.open("orb-composer-drafts", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("drafts");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }));
}

async function idbGet<T>(key: string): Promise<T | undefined> {
  if (typeof indexedDB === "undefined" || !indexedDB) return undefined;
  const d = await db();
  return new Promise<T | undefined>((resolve, reject) => {
    const request = d.transaction("drafts").objectStore("drafts").get(key);
    request.onsuccess = () => resolve(request.result as T | undefined);
    request.onerror = () => reject(request.error);
  });
}

async function idbPut(key: string, value: unknown): Promise<void> {
  if (typeof indexedDB === "undefined" || !indexedDB) return;
  const d = await db();
  return new Promise((resolve, reject) => {
    const tx = d.transaction("drafts", "readwrite");
    tx.objectStore("drafts").put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function idbDelete(key: string): Promise<void> {
  if (typeof indexedDB === "undefined" || !indexedDB) return;
  const d = await db();
  return new Promise((resolve, reject) => {
    const tx = d.transaction("drafts", "readwrite");
    tx.objectStore("drafts").delete(key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function readRecordWithMigration<T>(key: string): Promise<T | undefined> {
  const invoke = activeLocaldDrafts();
  if (invoke) {
    try {
      const raw = await invoke<string | null>("ui_draft_get", { key });
      if (typeof raw === "string" && raw) {
        return JSON.parse(raw) as T;
      }
    } catch (err) {
      if (isUnsupportedDraftCommandError(err)) unsupportedDraftInvoke = invoke;
    }
  }
  const legacy = await idbGet<T>(key);
  if (legacy !== undefined && invoke && invoke !== unsupportedDraftInvoke && !hasNonJsonBinaryInstance(legacy)) {
    void invoke("ui_draft_put", {
      key,
      updated_at: Date.now(),
      raw: JSON.stringify(legacy),
    }).catch(() => undefined);
  }
  return legacy;
}

async function writeRecord<T>(key: string, value: T): Promise<void> {
  const invoke = activeLocaldDrafts();
  if (invoke && !hasNonJsonBinaryInstance(value)) {
    try {
      await invoke("ui_draft_put", {
        key,
        updated_at: Date.now(),
        raw: JSON.stringify(value),
      });
      return;
    } catch (err) {
      if (isUnsupportedDraftCommandError(err)) {
        unsupportedDraftInvoke = invoke;
      }
      // Fall through to IndexedDB on binary/oversized payload or older daemon.
    }
  }
  await idbPut(key, value);
}

async function deleteRecord(key: string): Promise<void> {
  const invoke = activeLocaldDrafts();
  if (invoke) {
    try {
      await invoke("ui_draft_delete", { key });
    } catch (err) {
      if (isUnsupportedDraftCommandError(err)) unsupportedDraftInvoke = invoke;
    }
  }
  if (typeof indexedDB !== "undefined" && indexedDB) {
    await idbDelete(key).catch(() => undefined);
  }
}

export function isEmptyComposerDraft(draft: ComposerDraft): boolean {
  return !draft.text && !draft.images.length && !draft.mode && !(draft.uploads && draft.uploads.length);
}

export async function readComposerDraft(scope: string): Promise<ComposerDraft | undefined> {
  if (currentDrafts.has(scope)) return currentDrafts.get(scope);
  const stored = await readRecordWithMigration<ComposerDraft>(scope);
  return currentDrafts.get(scope) ?? stored;
}

export async function saveComposerDraft(scope: string, draft: ComposerDraft): Promise<void> {
  currentDrafts.set(scope, draft);
  if (isEmptyComposerDraft(draft)) {
    await deleteRecord(scope);
    return;
  }
  const invoke = activeLocaldDrafts();
  if (invoke && hasNonJsonBinaryInstance(draft)) {
    // Remove any older SQLite entry so IndexedDB's File-bearing draft isn't shadowed on read.
    await invoke("ui_draft_delete", { key: scope }).catch(() => undefined);
    await idbPut(scope, draft);
    return;
  }
  await writeRecord(scope, draft);
}

/** Large side transcripts may include image bytes; keep them out of localStorage. */
export async function readSideThread<T>(scope: string): Promise<T | undefined> {
  return readRecordWithMigration<T>(`thread:${scope}`);
}

export async function saveSideThread<T>(scope: string, value: T): Promise<void> {
  await writeRecord(`thread:${scope}`, value);
}

export async function updateSideThread<T>(
  scope: string,
  updater: (current: T | undefined) => T | undefined,
): Promise<{ updated: boolean; value: T | undefined }> {
  const key = `thread:${scope}`;
  const invoke = activeLocaldDrafts();
  if (invoke) {
    const prevLock = sideThreadLocks.get(key) ?? Promise.resolve();
    let release!: () => void;
    const gate = new Promise<void>((r) => {
      release = r;
    });
    sideThreadLocks.set(key, prevLock.then(() => gate, () => gate));
    await prevLock.catch(() => undefined);
    try {
      const current = await readRecordWithMigration<T>(key);
      const next = updater(current);
      if (next !== undefined) {
        await writeRecord(key, next);
        return { updated: true, value: next };
      }
      return { updated: false, value: next };
    } finally {
      release();
      if (sideThreadLocks.get(key) === gate) sideThreadLocks.delete(key);
    }
  }
  const d = await db();
  return new Promise((resolve, reject) => {
    const tx = d.transaction("drafts", "readwrite");
    const store = tx.objectStore("drafts");
    const req = store.get(key);
    let updated = false;
    let next: T | undefined;
    req.onsuccess = () => {
      try {
        next = updater(req.result as T | undefined);
        if (next !== undefined) {
          updated = true;
          store.put(next, key);
        }
      } catch (err) {
        tx.abort();
        reject(err);
      }
    };
    req.onerror = () => reject(req.error);
    tx.oncomplete = () => resolve({ updated, value: next });
    tx.onerror = () => reject(tx.error);
  });
}

export function resetComposerDraftsMemoryForTest(): void {
  currentDrafts.clear();
  sideThreadLocks.clear();
  unsupportedDraftInvoke = null;
  database = undefined;
}
