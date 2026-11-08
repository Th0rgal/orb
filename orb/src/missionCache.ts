import { createEffect, createRoot, createSignal, untrack } from "solid-js";
import { listQueuedMessages, type Mission } from "./api";
import * as apiModule from "./api";

function connectionVersionSafe(): number {
  return "connectionVersion" in apiModule && typeof apiModule.connectionVersion === "function"
    ? apiModule.connectionVersion()
    : 0;
}
import { historyScope } from "./resourceCache";
import {
  MAX_WARM_MISSIONS,
  isBackgroundSyncActive,
  onBackgroundSyncActiveChange,
  selectWarmMissionIds,
} from "./backgroundSync";
import { applyStreamEvent, applyStreamEvents, buildTranscript, clearTranscriptSessions, dropTranscriptSession, dropTranscriptSessionsByPrefixIfNot, transcriptSessionKey, type StreamItem } from "./transcriptModel";
import * as streamModule from "./stream";
import {
  getMissionEventPage,
  getMissionEventPreview,
  heldAfterHistory,
  storedToStream,
  streamMission,
  type StoredEvent,
  type StreamEvent,
} from "./stream";
import { cacheDelete, cachePeek, cachePut, cacheRecents, onCacheEvict } from "./pageCache";
import { currentLinkBudget, onLinkBudgetChange } from "./networkHealth";
import { loadPersistedTranscript, savePersistedTranscript } from "./persistentCache";

function transcriptPersistScope(): string {
  return "getJwt" in apiModule &&
    "getApiUrl" in apiModule &&
    typeof apiModule.getJwt === "function" &&
    typeof apiModule.getApiUrl === "function"
    ? historyScope()
    : `c:${connectionVersionSafe()}`;
}

export type TranscriptSnap = {
  activity?: string;
  items: StreamItem[];
  stream: StreamEvent[];
  liveTail?: StreamEvent[];
  fromLog?: boolean;
  detailsPending?: boolean;
  spineComplete?: boolean;
  spineBefore?: number;
  queueError?: string;
  cursor?: number;
  before?: number;
  hasOlder?: boolean;
};

const key = (id: string) => {
  syncConnectionChange();
  return `c:${connectionVersionSafe()}:m:${id}:tx`;
};
const heightKey = (id: string) => `c:${connectionVersionSafe()}:m:${id}:h`;
const sessionFor = (id: string) => transcriptSessionKey(id, connectionVersionSafe());
const previewSessionFor = (id: string) => `${sessionFor(id)}:preview`;

const [transcriptVersion, setTranscriptVersion] = createSignal(0);
export { transcriptVersion };

let bumpTimer: ReturnType<typeof setTimeout> | undefined;
function bumpTranscriptVersion() {
  if (bumpTimer !== undefined) return;
  bumpTimer = setTimeout(() => {
    bumpTimer = undefined;
    setTranscriptVersion((v) => v + 1);
  }, 16);
}

export type MissionStreamViewHandlers = {
  onEvent: (ev: StreamEvent) => void;
  onBatch: (evs: StreamEvent[]) => void;
  onLagged: () => void;
  onReady: () => void;
  onDisconnected: () => void;
  onCaughtUp?: (cursor: number | null, replayed: number) => void;
};

export type WarmMissionSettingsPatch = Partial<
  Pick<
    Mission,
    | "backend"
    | "agent"
    | "model_override"
    | "model_effort"
    | "fast_mode"
    | "service_tier"
    | "config_profile"
    | "session_id"
    | "updated_at"
  >
>;

export type WarmMissionPatch = WarmMissionSettingsPatch & {
  status?: string;
  status_message?: string;
};

export type WarmBtwTargets = {
  btwByParent: Readonly<Record<string, string | undefined>>;
  openBtwParentIds: readonly string[];
};

type WarmMissionSub = {
  scope: string;
  connVer: number;
  id: string;
  stop: () => void;
  healthy: boolean;
  caughtUp: boolean;
  cursor?: number;
  lastStatus?: string;
  lastStatusSummary?: string;
  lastStatusAtMs?: number;
  lastSettingsPatch?: WarmMissionSettingsPatch;
  lastSettingsAtMs?: number;
  views: Set<MissionStreamViewHandlers>;
};

const recentlyOpened = new Map<string, string>();
const liveMissionIds = new Map<string, string>();
const cachedScopes = new Set<string>();
const active = new Map<string, { refs: number; snapshot?: TranscriptSnap }>();
const warmSubs = new Map<string, WarmMissionSub>();
const dirtyMissions = new Set<string>();
let warmBtwProvider: (() => WarmBtwTargets) | undefined;
let warmReconcileListeners = new Set<() => void>();

function rememberWarmRecent(scope: string, id: string) {
  recentlyOpened.delete(scope);
  recentlyOpened.set(scope, id);
  while (recentlyOpened.size > MAX_WARM_MISSIONS) {
    recentlyOpened.delete(recentlyOpened.keys().next().value!);
  }
}

export function noteLiveMissionIds(ids: readonly string[]): void {
  const ver = connectionVersionSafe();
  const prefix = `c:${ver}:`;
  const next = new Map<string, string>();
  for (const id of ids) {
    if (!id) continue;
    const scope = key(id);
    next.set(scope, id);
    if (peekReadyTranscript(id)) rememberWarmRecent(scope, id);
  }
  for (const [scope, id] of liveMissionIds) {
    if (!next.has(scope) && scope.startsWith(prefix) && peekReadyTranscript(id)) {
      rememberWarmRecent(scope, id);
    }
  }
  liveMissionIds.clear();
  for (const [scope, id] of next) liveMissionIds.set(scope, id);
  reconcileWarmSubscriptions();
}

export function registerWarmBtwTargets(
  provider: () => WarmBtwTargets,
  onReconcile?: () => void,
): () => void {
  warmBtwProvider = provider;
  if (onReconcile) warmReconcileListeners.add(onReconcile);
  return () => {
    if (warmBtwProvider === provider) warmBtwProvider = undefined;
    if (onReconcile) warmReconcileListeners.delete(onReconcile);
  };
}

export function extractMissionSettingsPatch(
  data: Record<string, unknown> | undefined,
): WarmMissionSettingsPatch {
  const d = data ?? {};
  return {
    ...(typeof d.backend === "string" ? { backend: d.backend } : {}),
    ...("agent" in d ? { agent: typeof d.agent === "string" ? d.agent : null } : {}),
    ...("model_override" in d ? { model_override: typeof d.model_override === "string" ? d.model_override : null } : {}),
    ...("model_effort" in d ? { model_effort: typeof d.model_effort === "string" ? d.model_effort : null } : {}),
    ...(typeof d.fast_mode === "boolean" ? { fast_mode: d.fast_mode } : {}),
    ...("service_tier" in d
      ? { service_tier: typeof d.service_tier === "string" ? (d.service_tier as Mission["service_tier"]) : undefined }
      : {}),
    ...("config_profile" in d ? { config_profile: typeof d.config_profile === "string" ? d.config_profile : null } : {}),
    ...("session_id" in d ? { session_id: typeof d.session_id === "string" ? d.session_id : null } : {}),
    ...(typeof d.updated_at === "string" ? { updated_at: d.updated_at } : {}),
  };
}

const persistTimers = new Map<string, ReturnType<typeof setTimeout>>();

function missionIdFromScope(scope: string): string | null {
  const m = /^c:\d+:m:(.+):tx$/.exec(scope);
  return m ? m[1] : null;
}

function schedulePersistReadySnapshot(scope: string, snapshot: TranscriptSnap) {
  if (!snapshot.fromLog || snapshot.detailsPending) return;
  const missionId = missionIdFromScope(scope);
  if (!missionId) return;
  const existing = persistTimers.get(scope);
  if (existing !== undefined) clearTimeout(existing);
  const persistScope = transcriptPersistScope();
  const ver = connectionVersionSafe();
  const timer = setTimeout(() => {
    persistTimers.delete(scope);
    if (ver !== connectionVersionSafe()) return;
    void savePersistedTranscript(persistScope, missionId, snapshot);
  }, 250);
  persistTimers.set(scope, timer);
}

function saveSnapshot(scope: string, snapshot: TranscriptSnap, persist = true) {
  cachedScopes.add(scope);
  const entry = active.get(scope);
  if (entry) entry.snapshot = snapshot;
  else cachePut(scope, snapshot);
  const liveId = liveMissionIds.get(scope);
  if (liveId && snapshot.fromLog && !snapshot.detailsPending) {
    rememberWarmRecent(scope, liveId);
  }
  if (persist) schedulePersistReadySnapshot(scope, snapshot);
  bumpTranscriptVersion();
}

const hydratingFromDisk = new Map<string, Promise<TranscriptSnap | undefined>>();

let observedConnectionVersion = untrack(connectionVersionSafe);
function cleanupStaleConnectionState(nextVer: number) {
  const prefix = `c:${nextVer}:`;
  for (const [scope, timer] of [...persistTimers]) {
    if (!scope.startsWith(prefix)) {
      clearTimeout(timer);
      persistTimers.delete(scope);
    }
  }
  for (const scope of [...hydratingFromDisk.keys()]) {
    if (!scope.startsWith(prefix)) hydratingFromDisk.delete(scope);
  }
  for (const [scope, sub] of [...warmSubs]) {
    if (sub.connVer !== nextVer) {
      sub.stop();
      warmSubs.delete(scope);
    }
  }
  for (const scope of [...dirtyMissions]) {
    if (!scope.startsWith(prefix)) dirtyMissions.delete(scope);
  }
  for (const scope of [...recentlyOpened.keys()]) {
    if (!scope.startsWith(prefix)) recentlyOpened.delete(scope);
  }
  for (const scope of [...liveMissionIds.keys()]) {
    if (!scope.startsWith(prefix)) liveMissionIds.delete(scope);
  }
  for (const scope of [...cachedScopes]) {
    if (!scope.startsWith(prefix)) cachedScopes.delete(scope);
  }
  for (const scope of [...prefetchPaused.keys()]) {
    if (!scope.startsWith(prefix)) prefetchPaused.delete(scope);
  }
  for (const scope of [...prefetchQueue.keys()]) {
    if (!scope.startsWith(prefix)) prefetchQueue.delete(scope);
  }
  const sessionPrefix = `c:${nextVer}:m:`;
  dropTranscriptSessionsByPrefixIfNot(sessionPrefix);
  observedConnectionVersion = nextVer;
}

function syncConnectionChange() {
  const current = untrack(connectionVersionSafe);
  if (current !== observedConnectionVersion) {
    cleanupStaleConnectionState(current);
  }
}

createRoot(() => {
  createEffect(() => {
    const current = connectionVersionSafe();
    if (current !== observedConnectionVersion) {
      cleanupStaleConnectionState(current);
    }
  });
});

export function hydrateTranscriptFromDisk(id: string): Promise<TranscriptSnap | undefined> {
  syncConnectionChange();
  const existingReady = peekReadyTranscript(id);
  if (existingReady) return Promise.resolve(existingReady);
  const scope = key(id);
  const inflightHydrate = hydratingFromDisk.get(scope);
  if (inflightHydrate) return inflightHydrate;
  const ver = connectionVersionSafe();
  const persistScope = transcriptPersistScope();
  const p = loadPersistedTranscript<TranscriptSnap>(persistScope, id)
    .then((persisted) => {
      if (ver !== connectionVersionSafe() || !persisted?.fromLog || persisted.detailsPending) {
        return undefined;
      }
      if (!peekReadyTranscript(id)) {
        const session = sessionFor(id);
        const rebuiltItems = buildTranscript(
          [...(persisted.stream ?? []), ...(persisted.liveTail ?? [])],
          session,
        );
        const hydrated: TranscriptSnap = { ...persisted, items: rebuiltItems };
        saveSnapshot(scope, hydrated, false);
        dirtyMissions.add(scope);
      }
      return peekReadyTranscript(id);
    })
    .catch(() => undefined)
    .finally(() => {
      if (hydratingFromDisk.get(scope) === p) hydratingFromDisk.delete(scope);
    });
  hydratingFromDisk.set(scope, p);
  return p;
}

export function retainTranscript(id: string): () => void {
  const scope = key(id);
  rememberWarmRecent(scope, id);
  let entry = active.get(scope);
  if (entry) entry.refs++;
  else {
    entry = { refs: 1, snapshot: cachePeek<TranscriptSnap>(scope) };
    cacheDelete(scope);
    active.set(scope, entry);
    if (!entry.snapshot) {
      void hydrateTranscriptFromDisk(id);
    }
  }
  reconcileWarmSubscriptions();
  return () => {
    const cur = active.get(scope);
    if (cur && --cur.refs === 0) {
      active.delete(scope);
      if (cur.snapshot) cachePut(scope, cur.snapshot);
      reconcileWarmSubscriptions();
    }
  };
}

export function peekTranscript(id: string): TranscriptSnap | undefined {
  return active.get(key(id))?.snapshot ?? cachePeek<TranscriptSnap>(key(id));
}

/** Full event-log snapshot, safe to paint on first open. */
export function peekReadyTranscript(id: string): TranscriptSnap | undefined {
  const snap = peekTranscript(id);
  return snap?.fromLog && !snap.detailsPending ? snap : undefined;
}

export function peekTranscriptHeight(id: string): number | undefined {
  return cachePeek<number>(heightKey(id));
}

export function putTranscript(id: string, snap: TranscriptSnap) {
  saveSnapshot(key(id), { ...snap, fromLog: snap.fromLog !== false });
  reconcileWarmSubscriptions();
}

export function putTranscriptItems(id: string, items: StreamItem[]) {
  const prev = peekTranscript(id);
  if (prev?.fromLog) return;
  saveSnapshot(key(id), { items, stream: [], fromLog: false });
}

export function applyLiveEventsToTranscriptCache(
  id: string,
  evs: StreamEvent[],
  precomputedItems?: StreamItem[],
): void {
  if (!evs.length) return;
  const scope = key(id);
  const prev = peekTranscript(id);
  const session = sessionFor(id);
  const items = precomputedItems ?? applyStreamEvents(prev?.items ?? [], evs, session);
  let cursor = prev?.cursor;
  const sequenced: StreamEvent[] = [];
  const unsequenced: StreamEvent[] = [];
  for (const ev of evs) {
    if (typeof ev.sequence === "number" && Number.isSafeInteger(ev.sequence)) {
      cursor = cursor === undefined ? ev.sequence : Math.max(cursor, ev.sequence);
      sequenced.push(ev);
    } else {
      unsequenced.push(ev);
    }
  }
  const stream = sequenced.length
    ? mergeStreamBySequence(prev?.stream ?? [], sequenced)
    : (prev?.stream ?? []);
  const priorTail = prev?.liveTail ?? [];
  const combinedTail = unsequenced.length ? [...priorTail, ...unsequenced] : priorTail;
  const liveTail = combinedTail.length > 256 ? combinedTail.slice(-256) : combinedTail;
  saveSnapshot(scope, {
    ...(prev ?? {}),
    items,
    stream,
    ...(liveTail.length ? { liveTail } : {}),
    ...(cursor !== undefined ? { cursor } : {}),
    fromLog: prev?.fromLog === true,
  });
}

export function isMissionWarmLive(id: string): boolean {
  const scope = key(id);
  const sub = warmSubs.get(scope);
  return Boolean(
    peekReadyTranscript(id) &&
      sub &&
      sub.connVer === connectionVersionSafe() &&
      sub.healthy &&
      sub.caughtUp &&
      !dirtyMissions.has(scope),
  );
}

export function isMissionDirtyWhileUnfocused(id: string): boolean {
  return dirtyMissions.has(key(id));
}

export function peekWarmMissionStatus(
  id: string,
): { status: string; summary?: string } | undefined {
  const sub = warmSubs.get(key(id));
  if (!sub || sub.connVer !== connectionVersionSafe() || !sub.healthy || !sub.caughtUp || !sub.lastStatus) {
    return undefined;
  }
  return { status: sub.lastStatus, summary: sub.lastStatusSummary };
}

export function peekWarmMissionPatch(id: string): WarmMissionPatch | undefined {
  const sub = warmSubs.get(key(id));
  if (!sub || sub.connVer !== connectionVersionSafe() || !sub.healthy || !sub.caughtUp) return undefined;
  if (!sub.lastStatus && !sub.lastSettingsPatch) return undefined;
  return {
    ...(sub.lastSettingsPatch ?? {}),
    ...(sub.lastStatus ? { status: sub.lastStatus } : {}),
    ...(sub.lastStatusSummary !== undefined ? { status_message: sub.lastStatusSummary } : {}),
  };
}

export function clearWarmMissionSettingsPatch(id: string): void {
  const sub = warmSubs.get(key(id));
  if (!sub || sub.connVer !== connectionVersionSafe()) return;
  sub.lastSettingsPatch = undefined;
  sub.lastSettingsAtMs = undefined;
}

export function applyWarmMissionPatch(
  mission: Mission | null | undefined,
  options?: { preserveSettings?: boolean },
): Mission | null {
  if (!mission) return null;
  const sub = warmSubs.get(key(mission.id));
  if (!sub || sub.connVer !== connectionVersionSafe() || !sub.healthy || !sub.caughtUp) return mission;
  if (!sub.lastStatus && !sub.lastSettingsPatch) return mission;

  const missionTs = Date.parse(mission.updated_at || "");
  const applyStatus =
    Boolean(sub.lastStatus) &&
    (Number.isNaN(missionTs) || sub.lastStatusAtMs === undefined || sub.lastStatusAtMs >= missionTs);
  const applySettings =
    !options?.preserveSettings &&
    Boolean(sub.lastSettingsPatch) &&
    (Number.isNaN(missionTs) ||
      sub.lastSettingsAtMs === undefined ||
      sub.lastSettingsAtMs >= missionTs);

  if (!applyStatus && !applySettings) return mission;
  return {
    ...mission,
    ...(applySettings ? sub.lastSettingsPatch : {}),
    ...(applyStatus && sub.lastStatus ? { status: sub.lastStatus } : {}),
    ...(applyStatus && sub.lastStatusSummary !== undefined
      ? { status_message: sub.lastStatusSummary }
      : {}),
  };
}

export function isMissionStreamCaughtUp(id: string): boolean {
  const sub = warmSubs.get(key(id));
  return Boolean(sub && sub.connVer === connectionVersionSafe() && sub.healthy && sub.caughtUp);
}

export function noteMissionPresentationHint(id: string, kind: unknown): void {
  const scope = key(id);
  const sub = warmSubs.get(scope);
  if (sub && sub.healthy && sub.caughtUp) return;
  if (kind !== "mission_activity") {
    dirtyMissions.add(scope);
  }
}

export function markUnfocusedMissionsDirty(): void {
  const ver = connectionVersionSafe();
  const prefix = `c:${ver}:`;
  const scopes = new Set<string>(recentlyOpened.keys());
  for (const scope of cachedScopes) {
    if (scope.startsWith(prefix)) scopes.add(scope);
  }
  for (const scope of scopes) {
    const sub = warmSubs.get(scope);
    if (!sub || !sub.healthy || !sub.caughtUp) {
      dirtyMissions.add(scope);
    }
  }
}

function ensureWarmSub(id: string, initialSinceSeq?: number): WarmMissionSub {
  const scope = key(id);
  const ver = connectionVersionSafe();
  const existing = warmSubs.get(scope);
  if (existing && existing.connVer === ver) return existing;
  existing?.stop();

  const startCursor = peekReadyTranscript(id)?.cursor ?? initialSinceSeq;
  const sub: WarmMissionSub = {
    scope,
    connVer: ver,
    id,
    stop: () => {},
    healthy: false,
    caughtUp: false,
    cursor: startCursor,
    views: new Set(),
  };
  warmSubs.set(scope, sub);

  const noteSeq = (ev: StreamEvent) => {
    if (typeof ev.sequence === "number" && Number.isSafeInteger(ev.sequence)) {
      sub.cursor = sub.cursor === undefined ? ev.sequence : Math.max(sub.cursor, ev.sequence);
    }
  };

  const handleBatch = (evs: StreamEvent[]) => {
    if (!evs.length) return;
    for (const ev of evs) noteSeq(ev);
    if (sub.views.size > 0) {
      for (const v of sub.views) v.onBatch(evs);
    } else if (peekTranscript(id)) {
      applyLiveEventsToTranscriptCache(id, evs);
    }
  };

  const handleEvent = (ev: StreamEvent) => {
    noteSeq(ev);
    if (ev.type === "mission_settings_updated") {
      const extracted = extractMissionSettingsPatch(ev.data);
      const parsedUpdated = Date.parse(extracted.updated_at || "");
      const parsedAt = typeof ev.data.at === "string" ? Date.parse(ev.data.at) : Number.NaN;
      sub.lastSettingsAtMs = !Number.isNaN(parsedUpdated)
        ? parsedUpdated
        : !Number.isNaN(parsedAt)
          ? parsedAt
          : Date.now();
      sub.lastSettingsPatch = {
        ...(sub.lastSettingsPatch ?? {}),
        ...extracted,
      };
      if (sub.views.size > 0) {
        for (const v of sub.views) v.onEvent(ev);
      }
      return;
    }
    if (ev.type === "mission_status_changed" || ev.type === "status") {
      if (ev.type === "mission_status_changed" && typeof ev.data.status === "string") {
        sub.lastStatus = ev.data.status;
        sub.lastStatusSummary =
          typeof ev.data.summary === "string" ? ev.data.summary : undefined;
        const parsedAt = typeof ev.data.at === "string" ? Date.parse(ev.data.at) : Number.NaN;
        sub.lastStatusAtMs = !Number.isNaN(parsedAt) ? parsedAt : Date.now();
      }
      if (sub.views.size > 0) {
        for (const v of sub.views) v.onEvent(ev);
      } else if (ev.type === "mission_status_changed" && peekTranscript(id)) {
        // Close open live bubbles and record terminal error notices in the unfocused cache.
        applyLiveEventsToTranscriptCache(id, [ev]);
      }
      return;
    }
    handleBatch([ev]);
  };

  sub.stop = streamMission(
    id,
    handleEvent,
    () => {
      sub.caughtUp = false;
      dirtyMissions.add(scope);
      if (sub.views.size > 0) {
        for (const v of sub.views) v.onLagged();
      } else if (peekReadyTranscript(id)) {
        void refreshTranscript(id)
          .then((refreshed) => {
            if (warmSubs.get(scope) === sub && sub.healthy) {
              if (typeof refreshed.cursor === "number" && Number.isSafeInteger(refreshed.cursor)) {
                sub.cursor = sub.cursor === undefined ? refreshed.cursor : Math.max(sub.cursor, refreshed.cursor);
              }
              sub.caughtUp = true;
              dirtyMissions.delete(scope);
            }
          })
          .catch(() => {});
      }
    },
    () => {
      sub.healthy = true;
      for (const v of sub.views) v.onReady();
    },
    undefined,
    handleBatch,
    () => {
      sub.healthy = false;
      sub.caughtUp = false;
      sub.lastStatus = undefined;
      sub.lastStatusSummary = undefined;
      sub.lastStatusAtMs = undefined;
      sub.lastSettingsPatch = undefined;
      sub.lastSettingsAtMs = undefined;
      dirtyMissions.add(scope);
      for (const v of sub.views) v.onDisconnected();
    },
    startCursor,
    (cursor, replayed) => {
      sub.healthy = true;
      sub.caughtUp = true;
      dirtyMissions.delete(scope);
      if (typeof cursor === "number" && Number.isSafeInteger(cursor)) {
        sub.cursor = sub.cursor === undefined ? cursor : Math.max(sub.cursor, cursor);
        const snap = peekReadyTranscript(id);
        if (snap && (snap.cursor === undefined || cursor > snap.cursor)) {
          saveSnapshot(scope, { ...snap, cursor });
        }
      }
      for (const v of sub.views) v.onCaughtUp?.(cursor, replayed);
    },
  );
  return sub;
}

export function attachMissionStream(
  id: string,
  handlers: MissionStreamViewHandlers,
  options?: { initialSinceSeq?: number; keepWarmOnDetach?: boolean },
): () => void {
  const sub = ensureWarmSub(id, options?.initialSinceSeq);
  sub.views.add(handlers);
  if (sub.healthy) {
    queueMicrotask(() => {
      if (sub.views.has(handlers) && sub.healthy) {
        handlers.onReady();
        if (sub.caughtUp) {
          handlers.onCaughtUp?.(sub.cursor ?? peekReadyTranscript(id)?.cursor ?? null, 0);
        }
      }
    });
  }
  return () => {
    sub.views.delete(handlers);
    reconcileWarmSubscriptions();
  };
}

export function warmRecentMissionIds(includeBtw = false): string[] {
  const ver = connectionVersionSafe();
  const prefix = `c:${ver}:`;
  const focusedIds: string[] = [];
  for (const [scope, entry] of active) {
    if (entry.refs > 0 && scope.startsWith(prefix)) {
      const mid = recentlyOpened.get(scope) ?? liveMissionIds.get(scope) ?? scope.slice(prefix.length + 2, -3);
      if (mid) focusedIds.push(mid);
    }
  }
  const liveIds: string[] = [];
  for (const [scope, mid] of liveMissionIds) {
    if (scope.startsWith(prefix) && peekReadyTranscript(mid)) {
      liveIds.push(mid);
    }
  }
  const recentIds: string[] = [];
  const seenRecent = new Set<string>();
  const storedRecents = cacheRecents();
  for (let i = storedRecents.length - 1; i >= 0; i--) {
    const entry = storedRecents[i];
    if (!entry.startsWith("m:")) continue;
    const mid = entry.slice(2);
    if (mid && !seenRecent.has(mid) && peekReadyTranscript(mid)) {
      seenRecent.add(mid);
      recentIds.push(mid);
    }
  }
  for (const [scope, mid] of recentlyOpened) {
    if (scope.startsWith(prefix) && peekReadyTranscript(mid)) {
      const idx = recentIds.indexOf(mid);
      if (idx >= 0) recentIds.splice(idx, 1);
      recentIds.push(mid);
    }
  }
  const bgActive =
    Boolean(streamModule.isMultiplexSyncActive?.()) &&
    isBackgroundSyncActive() &&
    (typeof document === "undefined" || document.visibilityState !== "hidden");
  const btwTargets = includeBtw ? warmBtwProvider?.() : undefined;
  return selectWarmMissionIds({
    backgroundActive: bgActive,
    maxWarm: MAX_WARM_MISSIONS,
    focusedIds,
    liveIds,
    recentIds,
    ...(btwTargets
      ? {
          btwByParent: btwTargets.btwByParent,
          openBtwParentIds: btwTargets.openBtwParentIds,
        }
      : {}),
  });
}

let reconcilingWarmSubs = false;
export function reconcileWarmSubscriptions(): void {
  if (reconcilingWarmSubs) return;
  reconcilingWarmSubs = true;
  try {
    for (const cb of warmReconcileListeners) cb();
    const ver = connectionVersionSafe();
    for (const [scope, sub] of [...warmSubs]) {
      if (sub.connVer !== ver) {
        sub.stop();
        warmSubs.delete(scope);
      }
    }
    const wanted = new Set(warmRecentMissionIds(true));
    for (const [scope, sub] of [...warmSubs]) {
      if (sub.views.size === 0 && !wanted.has(sub.id)) {
        if (!sub.caughtUp) dirtyMissions.add(scope);
        sub.stop();
        warmSubs.delete(scope);
      }
    }
    if (Boolean(streamModule.isMultiplexSyncActive?.()) && isBackgroundSyncActive()) {
      for (const mid of wanted) {
        const scope = key(mid);
        if (!warmSubs.has(scope) && peekReadyTranscript(mid)) {
          ensureWarmSub(mid);
        }
      }
    }
  } finally {
    reconcilingWarmSubs = false;
  }
}

onBackgroundSyncActiveChange(() => reconcileWarmSubscriptions());
if (typeof document !== "undefined") {
  document.addEventListener("visibilitychange", () => reconcileWarmSubscriptions());
}

export function putTranscriptHeight(id: string, height: number) {
  if (height > 0) cachePut(heightKey(id), Math.round(height));
}

function mergeStreamBySequence(older: StreamEvent[], newer: StreamEvent[]): StreamEvent[] {
  const seen = new Set<string>();
  const idOf = (ev: StreamEvent) => ev.sequence !== undefined ? `seq:${ev.sequence}:${ev.type}` : ev.storedId !== undefined ? `id:${ev.storedId}:${ev.type}` : ev.eventId ? `ev:${ev.eventId}:${ev.type}` : undefined;
  const merged: StreamEvent[] = [];
  for (const ev of [...older, ...newer]) {
    const id = idOf(ev);
    if (id) {
      if (seen.has(id)) continue;
      seen.add(id);
    }
    merged.push(ev);
  }
  return merged.sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0));
}

async function fetchTranscript(id: string): Promise<TranscriptSnap> {
  const version=connectionVersionSafe();const check=()=>{if(version!==connectionVersionSafe())throw Error("Connection changed during transcript load.");};
  // Start pending queue read in parallel with the event page read rather than
  // blocking the event log round-trip on /queue. Any delivery racing this read
  // wins by message identity in the reducer; held SSE fills the live boundary.
  let queueError: string | undefined;
  const queuedPromise = listQueuedMessages(id).catch(error => {
    queueError = `Queued messages could not refresh: ${error instanceof Error ? error.message : String(error)}`;
    return [];
  });
  const previous = peekReadyTranscript(id) ?? (await hydrateTranscriptFromDisk(id));
  // Publish persisted messages before requesting activity, while racing the
  // full tail page in parallel so cold opens never pay an extra serial RTT.
  let preview: StreamEvent[] = [];
  let tailSettled = false;
  const previewPromise = !previous
    ? getMissionEventPreview(id)
        .then(page => {
          if (!page?.events.length || version !== connectionVersionSafe()) return;
          preview = spineAnswers(page.events.map(storedToStream).filter((e): e is StreamEvent => e !== null));
          if (!tailSettled && !peekReadyTranscript(id)) {
            saveSnapshot(key(id), {
              activity: page.activity,
              items: buildTranscript(preview, previewSessionFor(id)),
              stream: preview,
              fromLog: true,
              detailsPending: true,
            });
          }
        })
        .catch(() => {})
    : Promise.resolve();
  let stream:StreamEvent[]=[...(previous?.stream??[])];
  let retainedSpine:StreamEvent[]=[];
  let cursor=previous?.cursor, before=previous?.before, hasOlder=previous?.hasOlder;
  let spineComplete=previous?.spineComplete, spineBefore=previous?.spineBefore;
  let resets=0, forwardPages=0, jumpedForwardGap=false;
  for(;;){
   const page=await getMissionEventPage(id,cursor===undefined?{}:{since:cursor});
   tailSettled = true;
   check();
   if(page.reset){if(resets++)throw Error('Event history changed repeatedly during recovery.');stream.length=0;retainedSpine=[];cursor=undefined;before=undefined;hasOlder=undefined;spineComplete=undefined;spineBefore=undefined;forwardPages=0;jumpedForwardGap=false;continue;}
   const tailEvents:StreamEvent[]=[];
   for(const row of page.events){const event=storedToStream(row);if(event){stream.push(event);tailEvents.push(event);}}
   if(cursor===undefined){
    before=page.nextCursor;hasOlder=page.hasMore;cursor=page.pageMax??0;
    if(!hasOlder){spineComplete=true;spineBefore=undefined;}
    // When a tool-heavy turn exceeds the 200-event tail window (e.g. hundreds
    // or thousands of consecutive tool_call/tool_result events since the last
    // user_message, even if the turn's final assistant_message landed at the
    // very end of the 200-event tail) or we jumped a >400-event forward gap,
    // fetch the lightweight conversational spine (view=transcript) before
    // nextCursor so the user prompt and prior turns stay anchored above the
    // active work fold on first paint.
    const hasDeliveredUser = tailEvents.some(e => e.type === "user_message" && e.data.queued !== true);
    const hasNonCanonicalReply = tailEvents.some(e => e.type === "assistant_message" && e.data.canonical !== true);
    const hasWorkActivity = tailEvents.some(e => e.type === "tool_call" || e.type === "tool_result" || e.type === "thinking");
    if(hasOlder && before !== undefined && (jumpedForwardGap || (!hasDeliveredUser && (!hasNonCanonicalReply || hasWorkActivity)))){
     const spinePage = await getMissionEventPage(id, { before, view: "transcript" }).catch(() => null);
     check();
     if(spinePage){
      spineBefore = spinePage.nextCursor;
      spineComplete = !spinePage.hasMore;
      if(spinePage.events?.length){
       const firstTailConv = tailEvents.find(e => e.type === "user_message" || (e.type === "assistant_message" && e.data.success !== false));
       const spine = spineAnswers(spinePage.events.map(storedToStream).filter((e): e is StreamEvent => e !== null), firstTailConv?.type === "assistant_message");
       stream = mergeStreamBySequence(spine, stream);
      }
     } else {
      spineComplete = false;
     }
    }
    if(retainedSpine.length){
     stream = mergeStreamBySequence(retainedSpine, stream);
    }
    break;
   }
   if(page.nextCursor!==undefined){if(page.nextCursor<=cursor)throw Error('Event cursor did not advance.');cursor=page.nextCursor;}
   if(!page.hasMore)break;
   if(++forwardPages>=2){
    // More than 400 raw events streamed since our cached cursor (e.g. a long
    // offscreen tool storm). Preserve any already-cached conversational spine
    // turns, jump straight to the newest 200-event tail, and hydrate the
    // intervening conversational spine above instead of wiping scrollback.
    retainedSpine = spineAnswers(stream);
    stream=[];
    cursor=undefined;
    before=undefined;
    hasOlder=undefined;
    spineComplete=false;
    spineBefore=undefined;
    jumpedForwardGap=true;
   }
  }
  await previewPromise;
  stream=mergeStreamBySequence(preview,stream);
  const queued = await queuedPromise;
  check();
  const queueEvents: StreamEvent[] = queued.map(row => ({ type: "user_message", eventId: row.id, data: { id: row.id, content: row.content, queued: row.inflight !== true } }));
  const retainedLive = previous?.liveTail?.length ? heldAfterHistory(stream, previous.liveTail) : [];
  // History first puts accepted user turns at their actual transcript positions.
  return { items: buildTranscript([...stream, ...retainedLive, ...queueEvents], sessionFor(id)), stream, ...(retainedLive.length ? { liveTail: retainedLive } : {}), fromLog: true, spineComplete, ...(spineBefore !== undefined ? { spineBefore } : {}), queueError, cursor, before, hasOlder };
}

type JobKind='initial'|'refresh'|'older';
const jobs=new Map<string,{tail:Promise<unknown>;pending:Map<JobKind,Promise<TranscriptSnap>>}>();
function transcriptJob(id:string,kind:JobKind,load:()=>Promise<TranscriptSnap>):Promise<TranscriptSnap>{
 const scope=key(id),version=connectionVersionSafe();
 let job=jobs.get(scope);if(!job){job={tail:Promise.resolve(),pending:new Map()};jobs.set(scope,job);}
 const pending=job.pending.get(kind);if(pending)return pending;
 const owner=job;
 const result=owner.tail.catch(()=>{}).then(()=>{if(version!==connectionVersionSafe())throw Error('Connection changed during transcript load.');return load();}).then(snapshot=>{
  if(version!==connectionVersionSafe())throw Error('Connection changed during transcript load.');saveSnapshot(scope,snapshot);dirtyMissions.delete(scope);reconcileWarmSubscriptions();return snapshot;
 }).finally(()=>{owner.pending.delete(kind);if(!owner.pending.size)jobs.delete(scope);});
 owner.tail=result;owner.pending.set(kind,result);return result;
}
export function refreshTranscript(id:string):Promise<TranscriptSnap>{
 const scope=key(id),initial=jobs.get(scope)?.pending.get('initial');
 if(initial&&!peekReadyTranscript(id))return initial;
 return transcriptJob(id,'refresh',()=>fetchTranscript(id));
}
export function loadTranscript(id:string):Promise<TranscriptSnap>{
 const cached=peekReadyTranscript(id);
 if(cached)return Promise.resolve(cached);
 return transcriptJob(id,'initial',async()=>await hydrateTranscriptFromDisk(id)??await fetchTranscript(id));
}
// A transcript the cache cannot hold (too large), evicted under LRU pressure,
// or that could not load is not speculatively fetched again at every list
// refresh: that re-read whole event logs of large live fleets every 5 s.
const prefetchPaused=new Map<string,number>();
const PREFETCH_PAUSE_MS=10*60_000,PREFETCH_RETRY_MS=60_000;
export const MAX_LIVE_PREFETCH=8;
onCacheEvict((evictedKey)=>{
 if(evictedKey.endsWith(':tx')&&!active.has(evictedKey)){
  cachedScopes.delete(evictedKey);
  dropTranscriptSession(evictedKey.slice(0, -3));
  prefetchPaused.set(evictedKey,Date.now()+PREFETCH_PAUSE_MS);
 }
});
/** Pick at most `max` live missions ordered by most recent `updated_at` so a
 * 50-mission fleet never overflows `pageCache` (`MAX = 64`) in an infinite loop. */
export function selectLivePrefetchIds(missions: ReadonlyArray<{ id: string; status: string; updated_at?: string; created_at?: string }>, isLiveFn: (status: string) => boolean, max = MAX_LIVE_PREFETCH): string[] {
 return missions
  .filter(m => isLiveFn(m.status))
  .slice()
  .sort((a, b) => (Date.parse(b.updated_at || b.created_at || "") || 0) - (Date.parse(a.updated_at || a.created_at || "") || 0))
  .slice(0, max)
  .map(m => m.id);
}
// Keep speculative reads from occupying every connection when a conversation opens.
const prefetchQueue=new Map<string,string>();
let prefetchActive=0;
function pumpPrefetch(){
 if(!untrack(isBackgroundSyncActive))return;
 const p2Cap=currentLinkBudget().p2Cap;
 if(p2Cap<=0)return;
 const maxConc=Math.min(4,p2Cap);
 while(prefetchActive<maxConc&&prefetchQueue.size){
  const [scope,id]=prefetchQueue.entries().next().value!;
  prefetchQueue.delete(scope);
  if(scope!==key(id)||peekReadyTranscript(id)||jobs.has(scope))continue;
  prefetchActive++;
  void loadTranscript(id).then(()=>{if(!active.has(scope)&&cachePeek(scope)===undefined)prefetchPaused.set(scope,Date.now()+PREFETCH_PAUSE_MS);})
   .catch(()=>{prefetchPaused.set(scope,Date.now()+PREFETCH_RETRY_MS);})
   .finally(()=>{prefetchActive--;pumpPrefetch();});
 }
}
onBackgroundSyncActiveChange(()=>pumpPrefetch());
onLinkBudgetChange(()=>pumpPrefetch());
export function prefetchTranscript(id:string){
 const scope=key(id);
 if(peekReadyTranscript(id)||jobs.has(scope))return;
 const until=prefetchPaused.get(scope);if(until!==undefined&&until>Date.now())return;
 prefetchQueue.set(scope,id);
 pumpPrefetch();
}
export function forgetPrefetchPauses(){
  prefetchPaused.clear();
  prefetchQueue.clear();
  for (const [, timer] of persistTimers) clearTimeout(timer);
  persistTimers.clear();
  hydratingFromDisk.clear();
  for (const [, sub] of warmSubs) sub.stop();
  warmSubs.clear();
  dirtyMissions.clear();
  recentlyOpened.clear();
  liveMissionIds.clear();
  cachedScopes.clear();
  clearTranscriptSessions();
}
export function loadOlderTranscript(id:string):Promise<TranscriptSnap>{
 return transcriptJob(id,'older',async()=>{
  const previous=peekReadyTranscript(id);if(!previous)return fetchTranscript(id);
  if(!previous.hasOlder||previous.before===undefined)return previous;
  const page=await getMissionEventPage(id,{before:previous.before});
  if(page.hasMore&&(page.nextCursor===undefined||page.nextCursor>=previous.before))throw Error('Older event cursor did not advance.');
  const older=page.events.map(storedToStream).filter((e):e is StreamEvent=>e!==null);
  let stream=mergeStreamBySequence(older,previous.stream);
  let spineComplete = !page.hasMore ? true : previous.spineComplete;
  let spineBefore = !page.hasMore ? undefined : previous.spineBefore;
  const olderHasConv = older.some(e => (e.type === "user_message" && e.data.queued !== true) || (e.type === "assistant_message" && e.data.canonical !== true));
  if(page.hasMore && page.nextCursor !== undefined && !spineComplete && (!olderHasConv || (spineBefore !== undefined && page.nextCursor <= spineBefore))){
   const targetSpineBefore = spineBefore ?? page.nextCursor;
   const spinePage = await getMissionEventPage(id, { before: targetSpineBefore, view: "transcript" }).catch(() => null);
   if(spinePage){
    spineBefore = spinePage.nextCursor;
    spineComplete = !spinePage.hasMore;
    if(spinePage.events?.length){
     const firstConv = stream.find(e => e.type === "user_message" || (e.type === "assistant_message" && e.data.success !== false));
     const spine = spineAnswers(spinePage.events.map(storedToStream).filter((e): e is StreamEvent => e !== null), firstConv?.type === "assistant_message");
     stream = mergeStreamBySequence(spine, stream);
    }
   }
  }
  const session = sessionFor(id);
  let items=buildTranscript(stream, session);
  const preservedUsers: StreamEvent[] = [];
  for(const item of previous.items)if(item.kind==='user'&&item.messageId)preservedUsers.push({type:'user_message',data:{id:item.messageId,content:item.text,queued:item.queued,receipt:item.receipt,attached:item.attached}});
  items = applyStreamEvents(items, preservedUsers, session);
  return {...previous,stream,items,before:page.nextCursor??previous.before,hasOlder:page.hasMore,spineComplete,spineBefore};
 });
}

/** The conversational spine has user and assistant rows but none of the tool
 * calls between them. Its narration (text written between tool calls) would
 * read as one wall of "WAIT! Look at…" paragraphs, with nothing to fold it
 * into, until older raw pages arrive. Keep each turn's last assistant row (its
 * answer, or the newest narration of the running turn); the rest comes back,
 * with its tools, when the reader pages up. */
export function spineAnswers(spine: StreamEvent[], tailAnswered = false): StreamEvent[] {
  const keep: StreamEvent[] = [];
  let answered = tailAnswered; // a later assistant row of the same turn is kept
  for (let i = spine.length - 1; i >= 0; i--) {
    const event = spine[i];
    if (event.type === "user_message") answered = false;
    else if (event.type === "assistant_message" && event.data.success !== false) {
      if (answered) continue;
      answered = true;
    }
    keep.push(event);
  }
  return keep.reverse();
}

/** Hydrate the full user/final-assistant conversational spine (`view=transcript`)
 * for Cmd+F search without paging through thousands of intermediate tool events,
 * while preserving `before`/`hasOlder` for on-demand raw-event scrollback. */
export function prepareTranscriptSearch(id: string, signal?: AbortSignal): Promise<TranscriptSnap> {
  const ready = peekReadyTranscript(id);
  if (ready && (!ready.hasOlder || ready.before === undefined || ready.spineComplete)) {
    return Promise.resolve(ready);
  }
  return transcriptJob(id, "older", async () => {
    const current = peekReadyTranscript(id) ?? (await fetchTranscript(id));
    if (!current.hasOlder || current.before === undefined || current.spineComplete) {
      return { ...current, spineComplete: true };
    }
    let spineBefore: number | undefined = current.before;
    const olderRaw: StreamEvent[] = [];
    for (;;) {
      if (signal?.aborted || spineBefore === undefined) break;
      const page = await getMissionEventPage(id, { before: spineBefore, view: "transcript" });
      if (page.hasMore && (page.nextCursor === undefined || page.nextCursor >= spineBefore)) {
        throw Error("Older transcript spine cursor did not advance.");
      }
      const batch = page.events.map(storedToStream).filter((e): e is StreamEvent => e !== null);
      olderRaw.unshift(...batch);
      if (!page.hasMore || page.nextCursor === undefined) {
        spineBefore = undefined;
        break;
      }
      spineBefore = page.nextCursor;
    }
    if (signal?.aborted) return current;
    const firstConv = current.stream.find(
      (e) => e.type === "user_message" || (e.type === "assistant_message" && e.data.success !== false),
    );
    const spine = spineAnswers(olderRaw, firstConv?.type === "assistant_message");
    const stream = mergeStreamBySequence(spine, current.stream);
    const session = sessionFor(id);
    let items = buildTranscript(stream, session);
    for (const item of current.items) {
      if (item.kind === "user" && item.messageId) {
        items = applyStreamEvent(items, {
          type: "user_message",
          data: {
            id: item.messageId,
            content: item.text,
            queued: item.queued,
            receipt: item.receipt,
            attached: item.attached,
          },
        }, session);
      }
    }
    return {
      ...current,
      stream,
      items,
      spineComplete: true,
    };
  });
}

/** Refresh only a bounded recent set; never download tool histories offscreen. */
const presentationLoads = new Set<string>();
export async function refreshPresentationPreview(id: string) {
 const scope=key(id);
 if((!recentlyOpened.has(scope) && !cachedScopes.has(scope)) || active.has(scope) || isMissionWarmLive(id) || jobs.has(scope) || presentationLoads.has(scope)) return;
 presentationLoads.add(scope);
 try {
 const page=await getMissionEventPreview(id);
 if(scope!==key(id) || active.has(scope) || jobs.has(scope)) return;
 const prior=peekTranscript(id);
 const incoming=spineAnswers(page.events.map(storedToStream).filter((e):e is StreamEvent=>e!==null));
 if(prior?.fromLog && incoming.some(e => typeof e.sequence === "number" && e.sequence > (prior.cursor ?? 0))){
  dirtyMissions.add(scope);
 }
 const stream=mergeStreamBySequence(prior?.stream??[],incoming);
  saveSnapshot(scope,{...prior,activity:page.activity,stream,items:buildTranscript(stream, previewSessionFor(id)),fromLog:true,detailsPending:true});
 } finally { presentationLoads.delete(scope); }
}

export function recordPresentationActivity(id: string, label: unknown) {
 if(typeof label!=="string" || !label) return;
 const scope=key(id), prior=peekTranscript(id);
 if((!recentlyOpened.has(scope) && !cachedScopes.has(scope)) || !prior || active.has(scope)) return;
 saveSnapshot(scope,{...prior,activity:label.slice(0,160)});
}

/** Merge bounded passage-context events (and optional conversational spine)
 * into the cached transcript so deep search hits (>200 events back) render and
 * scroll without paging backward 200 rows at a time. */
export function hydratePassageEvents(id: string, rawEvents: StoredEvent[]): Promise<TranscriptSnap> {
  return transcriptJob(id, "older", async () => {
    const current = peekReadyTranscript(id) ?? (await fetchTranscript(id));
    const passageStream = rawEvents.map(storedToStream).filter((e): e is StreamEvent => e !== null);
    let spineStream: StreamEvent[] = [];
    let before = current.before;
    let hasOlder = current.hasOlder;
    if (current.hasOlder && current.before !== undefined) {
      const minPassageSeq = rawEvents.reduce((m, e) => Math.min(m, e.sequence), Infinity);
      if (minPassageSeq < current.before) {
        const spinePage = await getMissionEventPage(id, { before: current.before, view: "transcript" }).catch(() => null);
        if (spinePage) {
          if (spinePage.events.length) {
            spineStream = spineAnswers(spinePage.events.map(storedToStream).filter((e): e is StreamEvent => e !== null));
          }
          before = spinePage.nextCursor;
          hasOlder = spinePage.hasMore;
        }
      }
    }
    const mergedOlder = mergeStreamBySequence(spineStream, passageStream);
    const stream = mergeStreamBySequence(mergedOlder, current.stream);
    const session = sessionFor(id);
    let items = buildTranscript(stream, session);
    for (const item of current.items) {
      if (item.kind === "user" && item.messageId) {
        items = applyStreamEvent(items, {
          type: "user_message",
          data: { id: item.messageId, content: item.text, queued: item.queued, receipt: item.receipt, attached: item.attached },
        }, session);
      }
    }
    return { ...current, stream, items, before, hasOlder };
  });
}
