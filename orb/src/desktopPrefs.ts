import { clearConnection, getApiUrl, getJwt, setConnection } from "./api";
import { nativeInvoke } from "./native";
import { notifyExternalStorageChange } from "./storage";
import { getThemePref, setThemePref } from "./theme";

const POLL_VISIBLE_MS = 1_200;
const FLUSH_DEBOUNCE_MS = 35;
export const MAX_SHARED_PREF_BYTES = 65_536;

const utf8Encoder = new TextEncoder();
function utf8ByteLength(value: string): number {
  return utf8Encoder.encode(value).byteLength;
}

export function isSharedDesktopPrefKey(key: string): boolean {
  return (
    key.length > 0 &&
    utf8ByteLength(key) <= 512 &&
    (key === "orb-theme" || key.startsWith("orb.") || key.startsWith("orb:")) &&
    key !== "orb.jwt" &&
    key !== "orb.apiUrl" &&
    key !== "orb.selectedConversation" &&
    key !== "orb.recentPages" &&
    key !== "orb.githubOAuthPending" &&
    key !== "orb.projectedMove" &&
    key !== "orb.localFailures" &&
    key !== "orb.localFolderSeed" &&
    !key.startsWith("orb.catalog:") &&
    !key.startsWith("orb.software.inventory.") &&
    !key.startsWith("orb.inbox.") &&
    !key.startsWith("orb:inbox-digest:") &&
    !key.startsWith("orb.native.answered:") &&
    !key.startsWith("orb.turn-started:") &&
    (!key.startsWith("orb.btw:") || key.endsWith(',"settings:btw"]') || key.endsWith(',"settings:inbox"]'))
  );
}

type PrefsLoadResponse = {
  unchanged?: boolean;
  rev?: string;
  prefs?: Record<string, string>;
};

let initialized = false;
let storageHooked = false;
let applyingRemote = false;
let pullInFlight = false;
let flushRunning: Promise<void> | null = null;
let lastRev = "";
let lastSyncedConnSig: string | null = null;
let flushTimer: ReturnType<typeof setTimeout> | null = null;
let pollTimer: ReturnType<typeof setInterval> | null = null;

const pendingSet = new Map<string, string>();
const pendingRemove = new Set<string>();
let pendingClear = false;

let origSetItem: typeof Storage.prototype.setItem | null = null;
let origRemoveItem: typeof Storage.prototype.removeItem | null = null;
let origClear: typeof Storage.prototype.clear | null = null;

function rawSet(store: Storage, key: string, value: string): void {
  if (origSetItem) origSetItem.call(store, key, value);
  else store.setItem(key, value);
}

function rawRemove(store: Storage, key: string): void {
  if (origRemoveItem) origRemoveItem.call(store, key);
  else store.removeItem(key);
}

function connSig(url: string | null | undefined, token: string | null | undefined): string {
  const cleanUrl = (url ?? "").trim().replace(/\/+$/, "");
  const cleanTok = token ?? "";
  return cleanTok ? `${cleanUrl}\n${cleanTok}` : "";
}

function dispatchStorageChange(key: string, oldValue: string | null, newValue: string | null): void {
  notifyExternalStorageChange(key);
  if (key === "orb-theme") {
    const prev = applyingRemote;
    applyingRemote = true;
    try {
      setThemePref(getThemePref());
    } finally {
      applyingRemote = prev;
    }
  }
  if (typeof window !== "undefined" && typeof StorageEvent === "function") {
    try {
      window.dispatchEvent(new StorageEvent("storage", { key, oldValue, newValue }));
    } catch {
      // Happy-DOM / restricted test environments may reject synthetic StorageEvent init.
    }
  }
}

function applyRemoteSnapshot(remote: Record<string, string>, dispatchEvents: boolean): string[] {
  if (typeof localStorage === "undefined") return [];
  const store = localStorage;
  const changed: string[] = [];
  applyingRemote = true;
  try {
    const existingShared: string[] = [];
    for (let i = 0; i < store.length; i++) {
      const k = store.key(i);
      if (k && isSharedDesktopPrefKey(k)) existingShared.push(k);
    }
    for (const k of existingShared) {
      if (!(k in remote)) {
        const oldVal = store.getItem(k);
        if (oldVal !== null && utf8ByteLength(oldVal) > MAX_SHARED_PREF_BYTES) continue;
        rawRemove(store, k);
        changed.push(k);
        if (dispatchEvents) dispatchStorageChange(k, oldVal, null);
        else notifyExternalStorageChange(k);
      }
    }
    for (const [k, v] of Object.entries(remote)) {
      if (!isSharedDesktopPrefKey(k) || typeof v !== "string") continue;
      if (utf8ByteLength(v) > MAX_SHARED_PREF_BYTES) continue;
      const oldVal = store.getItem(k);
      if (oldVal !== null && utf8ByteLength(oldVal) > MAX_SHARED_PREF_BYTES) continue;
      if (oldVal !== v) {
        rawSet(store, k, v);
        changed.push(k);
        if (dispatchEvents) dispatchStorageChange(k, oldVal, v);
        else notifyExternalStorageChange(k);
      }
    }
    if (!dispatchEvents && changed.includes("orb-theme")) {
      setThemePref(getThemePref());
    }
  } finally {
    applyingRemote = false;
  }
  if (dispatchEvents && changed.length > 0 && typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("orb:desktop-prefs-changed", { detail: { keys: changed } }));
  }
  return changed;
}

async function drainFlushQueue(): Promise<void> {
  const invoke = nativeInvoke();
  if (!invoke) return;

  while (pendingClear || pendingSet.size > 0 || pendingRemove.size > 0) {
    const setObj: Record<string, string> = {};
    for (const [k, v] of pendingSet) setObj[k] = v;
    const removeArr = Array.from(pendingRemove);
    const clearAll = pendingClear;

    pendingSet.clear();
    pendingRemove.clear();
    pendingClear = false;

    try {
      const out = await invoke<{ rev?: string; prefs?: Record<string, string> }>("desktop_prefs_patch", {
        set: setObj,
        remove: removeArr,
        clear: clearAll,
      });
      if (
        out &&
        typeof out.rev === "string" &&
        out.rev &&
        out.prefs &&
        typeof out.prefs === "object" &&
        !pendingClear &&
        pendingSet.size === 0 &&
        pendingRemove.size === 0
      ) {
        applyRemoteSnapshot(out.prefs, true);
        lastRev = out.rev;
      }
    } catch {
      // Restore unsaved mutations without overriding newer pending edits queued while RPC was in flight.
      if (!pendingClear) {
        if (clearAll) {
          pendingClear = true;
        } else {
          for (const k of removeArr) {
            if (!pendingSet.has(k)) pendingRemove.add(k);
          }
        }
        for (const [k, v] of Object.entries(setObj)) {
          if (!pendingSet.has(k) && !pendingRemove.has(k)) {
            pendingSet.set(k, v);
          }
        }
      }
      break;
    }
  }
}

export async function flushDesktopPrefs(): Promise<void> {
  if (flushTimer !== null) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  if (flushRunning) {
    await flushRunning;
    if (!pendingClear && pendingSet.size === 0 && pendingRemove.size === 0) return;
  }
  if (!pendingClear && pendingSet.size === 0 && pendingRemove.size === 0) return;
  const p = drainFlushQueue().finally(() => {
    if (flushRunning === p) flushRunning = null;
  });
  flushRunning = p;
  await p;
}

function scheduleFlush(): void {
  if (flushTimer !== null) return;
  flushTimer = setTimeout(() => {
    flushTimer = null;
    void flushDesktopPrefs();
  }, FLUSH_DEBOUNCE_MS);
}

function installStorageHooks(): void {
  if (storageHooked || typeof Storage === "undefined" || typeof window === "undefined") return;
  storageHooked = true;
  origSetItem = Storage.prototype.setItem;
  origRemoveItem = Storage.prototype.removeItem;
  origClear = Storage.prototype.clear;

  Storage.prototype.setItem = function (key: string, value: string): void {
    const strVal = String(value);
    origSetItem!.call(this, key, strVal);
    if (!applyingRemote && this === window.localStorage && isSharedDesktopPrefKey(key)) {
      if (utf8ByteLength(strVal) <= MAX_SHARED_PREF_BYTES) {
        pendingRemove.delete(key);
        pendingSet.set(key, strVal);
        scheduleFlush();
      } else {
        pendingSet.delete(key);
        pendingRemove.delete(key);
      }
    }
  };

  Storage.prototype.removeItem = function (key: string): void {
    origRemoveItem!.call(this, key);
    if (!applyingRemote && this === window.localStorage && isSharedDesktopPrefKey(key)) {
      pendingSet.delete(key);
      pendingRemove.add(key);
      scheduleFlush();
    }
  };

  Storage.prototype.clear = function (): void {
    origClear!.call(this);
    if (!applyingRemote && this === window.localStorage) {
      pendingSet.clear();
      pendingRemove.clear();
      pendingClear = true;
      scheduleFlush();
    }
  };
}

export async function pullDesktopPrefs(checkConnection = false): Promise<void> {
  if (pullInFlight || flushRunning !== null) return;
  if (pendingClear || pendingSet.size > 0 || pendingRemove.size > 0) {
    await flushDesktopPrefs();
    if (pullInFlight || flushRunning !== null || pendingClear || pendingSet.size > 0 || pendingRemove.size > 0) {
      return;
    }
  }
  const invoke = nativeInvoke();
  if (!invoke) return;

  pullInFlight = true;
  try {
    const res = await invoke<PrefsLoadResponse>("desktop_prefs_load", lastRev ? { since_rev: lastRev } : {});
    if (res && typeof res === "object") {
      if (typeof res.rev === "string" && res.rev) lastRev = res.rev;
      if (res.unchanged === false && res.prefs && typeof res.prefs === "object") {
        if (!pendingClear && pendingSet.size === 0 && pendingRemove.size === 0) {
          applyRemoteSnapshot(res.prefs, true);
        }
      }
    }
    if (checkConnection) {
      const saved = await invoke<{ api_url?: string; token?: string } | null>("desktop_connection_load").catch(() => undefined);
      if (saved !== undefined) {
        const nextSig = connSig(saved?.api_url, saved?.token);
        if (lastSyncedConnSig !== null && nextSig !== lastSyncedConnSig) {
          lastSyncedConnSig = nextSig;
          if (saved?.api_url && saved?.token) {
            if (connSig(getApiUrl(), getJwt()) !== nextSig) {
              setConnection(saved.api_url, saved.token);
            }
          } else if (getJwt()) {
            clearConnection();
          }
        } else if (lastSyncedConnSig === null) {
          lastSyncedConnSig = nextSig;
        }
      }
    }
  } catch {
    // Ignore transient RPC errors when daemon is shutting down.
  } finally {
    pullInFlight = false;
  }
}

export async function initDesktopPrefs(): Promise<void> {
  if (initialized || typeof window === "undefined" || typeof localStorage === "undefined") return;
  const invoke = nativeInvoke();
  if (!invoke) return;

  let initial: PrefsLoadResponse | undefined;
  try {
    initial = await invoke<PrefsLoadResponse>("desktop_prefs_load", {});
  } catch {
    return;
  }
  if (!initial || typeof initial !== "object" || !initial.prefs || typeof initial.prefs !== "object") {
    return;
  }

  initialized = true;
  if (typeof initial.rev === "string") lastRev = initial.rev;

  // Collect local keys not yet present in shared ~/.orb/ui-prefs.json so first-run settings seed it.
  const seed: Record<string, string> = {};
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (!k || !isSharedDesktopPrefKey(k)) continue;
    if (!(k in initial.prefs)) {
      const v = localStorage.getItem(k);
      if (v !== null && utf8ByteLength(v) <= MAX_SHARED_PREF_BYTES) seed[k] = v;
    }
  }

  const mergedInitial = { ...seed, ...initial.prefs };
  applyRemoteSnapshot(mergedInitial, false);
  installStorageHooks();
  lastSyncedConnSig = connSig(getApiUrl(), getJwt());

  if (Object.keys(seed).length > 0) {
    for (const [k, v] of Object.entries(seed)) pendingSet.set(k, v);
    await flushDesktopPrefs();
  }

  const onFocus = () => { void pullDesktopPrefs(true); };
  const onVisibility = () => {
    if (document.visibilityState === "hidden") void flushDesktopPrefs();
    else void pullDesktopPrefs(true);
  };
  window.addEventListener("focus", onFocus);
  document.addEventListener("visibilitychange", onVisibility);
  window.addEventListener("pagehide", () => { void flushDesktopPrefs(); });

  pollTimer = setInterval(() => {
    if (typeof document !== "undefined" && document.visibilityState === "hidden") return;
    void pullDesktopPrefs(true);
  }, POLL_VISIBLE_MS);
}

/** Test hook: unhook Storage.prototype and clear module state. */
export function resetDesktopPrefsForTest(): void {
  if (flushTimer !== null) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  if (pollTimer !== null) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
  if (storageHooked && origSetItem && origRemoveItem && origClear) {
    Storage.prototype.setItem = origSetItem;
    Storage.prototype.removeItem = origRemoveItem;
    Storage.prototype.clear = origClear;
  }
  storageHooked = false;
  initialized = false;
  applyingRemote = false;
  pullInFlight = false;
  flushRunning = null;
  lastRev = "";
  lastSyncedConnSig = null;
  pendingSet.clear();
  pendingRemove.clear();
  pendingClear = false;
}
