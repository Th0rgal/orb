import {
  clearConnection,
  connectionVersion,
  getApiUrl,
  getJwt,
  isDesktopConnectionSaving,
  setConnection,
} from "./api";
import { reloadBackgroundSyncMode } from "./backgroundSync";
import { reloadApprovalGraceSecs } from "./deviceApproval";
import { nativeInvoke } from "./native";
import { notifyExternalStorageChange } from "./storage";
import { getThemePref, setThemePref } from "./theme";
import { reloadVoiceLanguage } from "./voice";

const POLL_VISIBLE_MS = 1_200;
const INIT_RETRY_MS = 1_200;
const FLUSH_DEBOUNCE_MS = 35;
const MIGRATED_KEY = "orb.desktopPrefsMigrated.v1";
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
    key !== MIGRATED_KEY &&
    !key.startsWith("orb.projectColorSync:") &&
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
  exists?: boolean;
  rev?: string;
  prefs?: Record<string, string>;
};

let initialized = false;
let hadFailedInit = false;
let initInFlight: Promise<void> | null = null;
let storageHooked = false;
let applyingRemote = false;
let pullInFlight = false;
let connCheckInFlight = false;
let flushRunning: Promise<void> | null = null;
let mutationEpoch = 0;
let lastRev = "";
let lastSyncedConnSig: string | null = null;
let lastObservedConnVersion = 0;
let initRetryTimer: ReturnType<typeof setTimeout> | null = null;
let flushTimer: ReturnType<typeof setTimeout> | null = null;
let pollTimer: ReturnType<typeof setInterval> | null = null;
let cleanupWindowListeners: (() => void) | null = null;

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

function reconcileModuleOwners(changed: readonly string[]): void {
  if (changed.includes("orb-theme")) {
    setThemePref(getThemePref());
  }
  if (changed.includes("orb.voiceLang")) {
    reloadVoiceLanguage();
  }
  if (changed.includes("orb.approvalGraceSecs")) {
    reloadApprovalGraceSecs();
  }
  if (changed.includes("orb:background-sync-mode")) {
    reloadBackgroundSyncMode();
  }
}

function dispatchStorageChange(key: string, oldValue: string | null, newValue: string | null): void {
  notifyExternalStorageChange(key);
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
    if (changed.length > 0) {
      reconcileModuleOwners(changed);
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
    const patchEpoch = mutationEpoch;

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
        mutationEpoch === patchEpoch &&
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
  if (!initialized) return;
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
  if (!initialized || flushTimer !== null) return;
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
      mutationEpoch++;
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
      mutationEpoch++;
      pendingSet.delete(key);
      pendingRemove.add(key);
      scheduleFlush();
    }
  };

  Storage.prototype.clear = function (): void {
    origClear!.call(this);
    if (!applyingRemote && this === window.localStorage) {
      mutationEpoch++;
      pendingSet.clear();
      pendingRemove.clear();
      pendingClear = true;
      scheduleFlush();
    }
  };
}

async function reconcileDesktopConnection(
  invoke: <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>,
): Promise<void> {
  if (isDesktopConnectionSaving()) return;
  const verBefore = connectionVersion();
  const localSigBefore = connSig(getApiUrl(), getJwt());
  const saved = await invoke<{ api_url?: string; token?: string } | null>("desktop_connection_load").catch(() => undefined);
  if (saved === undefined || connectionVersion() !== verBefore || isDesktopConnectionSaving()) return;
  const nextSig = connSig(saved?.api_url, saved?.token);
  if (verBefore !== lastObservedConnVersion) {
    if (nextSig === localSigBefore) {
      lastObservedConnVersion = verBefore;
      lastSyncedConnSig = nextSig;
    } else if (nextSig !== lastSyncedConnSig) {
      lastSyncedConnSig = nextSig;
      if (saved?.api_url && saved?.token) {
        if (connSig(getApiUrl(), getJwt()) !== nextSig) {
          setConnection(saved.api_url, saved.token, { persist: false });
        }
      } else if (getJwt()) {
        clearConnection({ persist: false });
      }
      lastObservedConnVersion = connectionVersion();
    }
    return;
  }
  if (lastSyncedConnSig !== null && nextSig !== lastSyncedConnSig) {
    lastSyncedConnSig = nextSig;
    if (saved?.api_url && saved?.token) {
      if (connSig(getApiUrl(), getJwt()) !== nextSig) {
        setConnection(saved.api_url, saved.token, { persist: false });
      }
    } else if (getJwt()) {
      clearConnection({ persist: false });
    }
    lastObservedConnVersion = connectionVersion();
  } else if (lastSyncedConnSig === null) {
    lastSyncedConnSig = nextSig;
    lastObservedConnVersion = verBefore;
  }
}

function ensureRuntimeWiring(): void {
  installStorageHooks();
  if (lastSyncedConnSig === null) {
    lastSyncedConnSig = connSig(getApiUrl(), getJwt());
    lastObservedConnVersion = connectionVersion();
  }
  if (!cleanupWindowListeners && typeof window !== "undefined" && typeof document !== "undefined") {
    const onFocus = () => { void pullDesktopPrefs(true); };
    const onVisibility = () => {
      if (document.visibilityState === "hidden") void flushDesktopPrefs();
      else void pullDesktopPrefs(true);
    };
    const onPageHide = () => { void flushDesktopPrefs(); };
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener("pagehide", onPageHide);
    cleanupWindowListeners = () => {
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("pagehide", onPageHide);
    };
  }
  if (pollTimer === null && typeof window !== "undefined") {
    pollTimer = setInterval(() => {
      if (typeof document !== "undefined" && document.visibilityState === "hidden") return;
      void pullDesktopPrefs(true);
    }, POLL_VISIBLE_MS);
  }
}

function scheduleInitRetry(): void {
  if (initialized || initRetryTimer !== null) return;
  initRetryTimer = setTimeout(() => {
    initRetryTimer = null;
    if (!initialized) void initDesktopPrefs();
  }, INIT_RETRY_MS);
}

async function maybeReconcileConnection(
  checkConnection: boolean,
  invoke: <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>,
): Promise<void> {
  if (!checkConnection || connCheckInFlight) return;
  connCheckInFlight = true;
  try {
    await reconcileDesktopConnection(invoke);
  } finally {
    connCheckInFlight = false;
  }
}

async function pullPrefsOnly(
  invoke: <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>,
): Promise<void> {
  if (pullInFlight || flushRunning !== null) return;
  if (pendingClear || pendingSet.size > 0 || pendingRemove.size > 0) {
    await flushDesktopPrefs();
    if (pullInFlight || flushRunning !== null || pendingClear || pendingSet.size > 0 || pendingRemove.size > 0) {
      return;
    }
  }

  pullInFlight = true;
  try {
    const loadEpoch = mutationEpoch;
    const res = await invoke<PrefsLoadResponse>("desktop_prefs_load", lastRev ? { since_rev: lastRev } : {});
    if (
      res &&
      typeof res === "object" &&
      mutationEpoch === loadEpoch &&
      !pendingClear &&
      pendingSet.size === 0 &&
      pendingRemove.size === 0 &&
      flushRunning === null
    ) {
      if (res.unchanged === true) {
        if (typeof res.rev === "string" && res.rev) lastRev = res.rev;
      } else if (res.prefs && typeof res.prefs === "object") {
        applyRemoteSnapshot(res.prefs, true);
        if (typeof res.rev === "string" && res.rev) lastRev = res.rev;
      }
    }
  } catch {
    // Ignore transient ui-prefs RPC errors.
  } finally {
    pullInFlight = false;
  }
}

export async function pullDesktopPrefs(checkConnection = false): Promise<void> {
  const invoke = nativeInvoke();
  if (!invoke) return;
  if (!initialized) {
    await Promise.all([maybeReconcileConnection(checkConnection, invoke), initDesktopPrefs()]);
    return;
  }
  await Promise.all([pullPrefsOnly(invoke), maybeReconcileConnection(checkConnection, invoke)]);
}

async function applyLoadedPrefsSnapshot(initial: PrefsLoadResponse): Promise<boolean> {
  if (!initial || typeof initial !== "object" || !initial.prefs || typeof initial.prefs !== "object") {
    return false;
  }

  if (initRetryTimer !== null) {
    clearTimeout(initRetryTimer);
    initRetryTimer = null;
  }
  if (typeof initial.rev === "string") lastRev = initial.rev;

  // Seed local keys only once per origin (or when shared ~/.orb/ui-prefs.json does not exist yet),
  // so reopening an already-migrated client never resurrects preferences removed by another client.
  const alreadyMigrated = localStorage.getItem(MIGRATED_KEY) === "1" && initial.exists !== false;
  const seed: Record<string, string> = {};
  if (!alreadyMigrated && !pendingClear) {
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (!k || !isSharedDesktopPrefKey(k)) continue;
      if (!(k in initial.prefs) && !pendingRemove.has(k) && !pendingSet.has(k)) {
        const v = localStorage.getItem(k);
        if (v !== null && utf8ByteLength(v) <= MAX_SHARED_PREF_BYTES) seed[k] = v;
      }
    }
  }

  const mergedInitial: Record<string, string> = pendingClear ? {} : { ...seed, ...initial.prefs };
  if (!pendingClear) {
    for (const k of pendingRemove) delete mergedInitial[k];
  }
  for (const [k, v] of pendingSet) {
    mergedInitial[k] = v;
  }

  applyRemoteSnapshot(mergedInitial, hadFailedInit);

  if (!pendingClear) {
    for (const [k, v] of Object.entries(seed)) {
      if (!pendingSet.has(k) && !pendingRemove.has(k)) pendingSet.set(k, v);
    }
  }

  initialized = true;
  hadFailedInit = false;

  if (pendingClear || pendingSet.size > 0 || pendingRemove.size > 0) {
    await flushDesktopPrefs();
    if (!pendingClear && pendingSet.size === 0 && pendingRemove.size === 0) {
      rawSet(localStorage, MIGRATED_KEY, "1");
    }
  } else if (!alreadyMigrated) {
    rawSet(localStorage, MIGRATED_KEY, "1");
  }
  return true;
}

export async function applyBootstrappedDesktopPrefs(initial: unknown): Promise<boolean> {
  if (initialized || typeof window === "undefined" || typeof localStorage === "undefined") {
    return initialized;
  }
  ensureRuntimeWiring();
  return applyLoadedPrefsSnapshot(initial as PrefsLoadResponse);
}

async function runInitDesktopPrefs(): Promise<void> {
  if (initialized || typeof window === "undefined" || typeof localStorage === "undefined") return;
  const invoke = nativeInvoke();
  if (!invoke) return;

  ensureRuntimeWiring();

  let initial: PrefsLoadResponse | undefined;
  try {
    initial = await invoke<PrefsLoadResponse>("desktop_prefs_load", {});
  } catch {
    hadFailedInit = true;
    await maybeReconcileConnection(true, invoke);
    scheduleInitRetry();
    return;
  }
  if (!(await applyLoadedPrefsSnapshot(initial!))) {
    hadFailedInit = true;
    await maybeReconcileConnection(true, invoke);
    scheduleInitRetry();
  }
}

export async function initDesktopPrefs(): Promise<void> {
  if (initialized) return;
  if (initInFlight) return initInFlight;
  const p = runInitDesktopPrefs().finally(() => {
    if (initInFlight === p) initInFlight = null;
  });
  initInFlight = p;
  return p;
}

/** Test hook: unhook Storage.prototype and clear module state. */
export function resetDesktopPrefsForTest(): void {
  if (cleanupWindowListeners) {
    cleanupWindowListeners();
    cleanupWindowListeners = null;
  }
  if (initRetryTimer !== null) {
    clearTimeout(initRetryTimer);
    initRetryTimer = null;
  }
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
  hadFailedInit = false;
  initInFlight = null;
  applyingRemote = false;
  pullInFlight = false;
  connCheckInFlight = false;
  flushRunning = null;
  mutationEpoch = 0;
  lastRev = "";
  lastSyncedConnSig = null;
  lastObservedConnVersion = 0;
  pendingSet.clear();
  pendingRemove.clear();
  pendingClear = false;
}
