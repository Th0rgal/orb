import { createSignal } from "solid-js";
import { connectionVersion, listQueuedMessages, type Mission } from "./api";
import {
  MAX_WARM_MISSIONS,
  isBackgroundSyncActive,
  onBackgroundSyncActiveChange,
  selectWarmMissionIds,
} from "./backgroundSync";
import { applyStreamEvent, applyStreamEvents, buildTranscript, type StreamItem } from "./transcriptModel";
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
import { cacheDelete, cachePeek, cachePut, onCacheEvict } from "./pageCache";

export type TranscriptSnap = {
  activity?: string;
  items: StreamItem[];
  stream: StreamEvent[];
  liveTail?: StreamEvent[];
  fromLog?: boolean;
  detailsPending?: boolean;
  spineComplete?: boolean;
  queueError?: string;
  cursor?: number;
  before?: number;
  hasOlder?: boolean;
};

const key = (id: string) => `c:${connectionVersion()}:m:${id}:tx`;
const heightKey = (id: string) => `c:${connectionVersion()}:m:${id}:h`;

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
  lastSettingsPatch?: WarmMissionSettingsPatch;
  views: Set<MissionStreamViewHandlers>;
};

const recentlyOpened = new Map<string, string>();
const active = new Map<string, { refs: number; snapshot?: TranscriptSnap }>();
const warmSubs = new Map<string, WarmMissionSub>();
const dirtyMissions = new Set<string>();
let warmBtwProvider: (() => WarmBtwTargets) | undefined;
let warmReconcileListeners = new Set<() => void>();

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

function saveSnapshot(scope: string, snapshot: TranscriptSnap) {
  const entry = active.get(scope);
  if (entry) entry.snapshot = snapshot;
  else cachePut(scope, snapshot);
  bumpTranscriptVersion();
}

export function retainTranscript(id: string): () => void {
  const scope = key(id);
  recentlyOpened.delete(scope);
  recentlyOpened.set(scope, id);
  while (recentlyOpened.size > MAX_WARM_MISSIONS) {
    recentlyOpened.delete(recentlyOpened.keys().next().value!);
  }
  let entry = active.get(scope);
  if (entry) entry.refs++;
  else {
    entry = { refs: 1, snapshot: cachePeek<TranscriptSnap>(scope) };
    cacheDelete(scope);
    active.set(scope, entry);
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
  const items = precomputedItems ?? applyStreamEvents(prev?.items ?? [], evs);
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
      sub.connVer === connectionVersion() &&
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
  if (!sub || sub.connVer !== connectionVersion() || !sub.lastStatus) return undefined;
  return { status: sub.lastStatus, summary: sub.lastStatusSummary };
}

export function peekWarmMissionPatch(id: string): WarmMissionPatch | undefined {
  const sub = warmSubs.get(key(id));
  if (!sub || sub.connVer !== connectionVersion()) return undefined;
  if (!sub.lastStatus && !sub.lastSettingsPatch) return undefined;
  return {
    ...(sub.lastSettingsPatch ?? {}),
    ...(sub.lastStatus ? { status: sub.lastStatus } : {}),
    ...(sub.lastStatusSummary !== undefined ? { status_message: sub.lastStatusSummary } : {}),
  };
}

export function applyWarmMissionPatch(mission: Mission | null | undefined): Mission | null {
  if (!mission) return null;
  const patch = peekWarmMissionPatch(mission.id);
  if (!patch) return mission;
  return { ...mission, ...patch };
}

export function isMissionStreamCaughtUp(id: string): boolean {
  const sub = warmSubs.get(key(id));
  return Boolean(sub && sub.connVer === connectionVersion() && sub.healthy && sub.caughtUp);
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
  for (const [scope] of recentlyOpened) {
    const sub = warmSubs.get(scope);
    if (!sub || !sub.healthy || !sub.caughtUp) {
      dirtyMissions.add(scope);
    }
  }
}

function ensureWarmSub(id: string, initialSinceSeq?: number): WarmMissionSub {
  const scope = key(id);
  const ver = connectionVersion();
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
      sub.lastSettingsPatch = {
        ...(sub.lastSettingsPatch ?? {}),
        ...extractMissionSettingsPatch(ev.data),
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
          .then(() => {
            if (warmSubs.get(scope) === sub && sub.healthy) {
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
  const ver = connectionVersion();
  const prefix = `c:${ver}:`;
  const focusedIds: string[] = [];
  for (const [scope, entry] of active) {
    if (entry.refs > 0 && scope.startsWith(prefix)) {
      const mid = recentlyOpened.get(scope) ?? scope.slice(prefix.length + 2, -3);
      if (mid) focusedIds.push(mid);
    }
  }
  const recentIds: string[] = [];
  for (const [scope, mid] of recentlyOpened) {
    if (scope.startsWith(prefix) && peekReadyTranscript(mid)) {
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
    const ver = connectionVersion();
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
  const version=connectionVersion();const check=()=>{if(version!==connectionVersion())throw Error("Connection changed during transcript load.");};
  // Start pending queue read in parallel with the event page read rather than
  // blocking the event log round-trip on /queue. Any delivery racing this read
  // wins by message identity in the reducer; held SSE fills the live boundary.
  let queueError: string | undefined;
  const queuedPromise = listQueuedMessages(id).catch(error => {
    queueError = `Queued messages could not refresh: ${error instanceof Error ? error.message : String(error)}`;
    return [];
  });
  const previous=peekReadyTranscript(id);
  // Publish persisted messages before requesting activity. A preview is readable,
  // but has no raw cursor and must never count as a complete replay.
  let preview:StreamEvent[]=[];
  if(!previous){
   const page=await getMissionEventPreview(id).catch(()=>null);
   check();
   if(page?.events.length){
    preview=spineAnswers(page.events.map(storedToStream).filter((e):e is StreamEvent=>e!==null));
    saveSnapshot(key(id),{activity:page.activity,items:buildTranscript(preview),stream:preview,fromLog:true,detailsPending:true});
   }
  }
  let stream:StreamEvent[]=[...(previous?.stream??[])];
  let cursor=previous?.cursor, before=previous?.before, hasOlder=previous?.hasOlder;
  let resets=0, forwardPages=0;
  for(;;){
   const page=await getMissionEventPage(id,cursor===undefined?{}:{since:cursor});
   check();
   if(page.reset){if(resets++)throw Error('Event history changed repeatedly during recovery.');stream.length=0;cursor=undefined;before=undefined;hasOlder=undefined;forwardPages=0;continue;}
   for(const row of page.events){const event=storedToStream(row);if(event)stream.push(event);}
   if(cursor===undefined){
    before=page.nextCursor;hasOlder=page.hasMore;cursor=page.pageMax??0;
    // When a tool-heavy turn exceeds the 200-event tail window (e.g. hundreds
    // or thousands of consecutive tool_call/tool_result events since the last
    // user/assistant message), the raw tail page has hasMore=true but lacks
    // the recent conversation turns. Fetch the lightweight conversational
    // spine (view=transcript) before nextCursor so the latest messages always
    // appear immediately above the active work fold on first paint.
    if(hasOlder && before !== undefined && !stream.some(e => (e.type === "user_message" && e.data.queued !== true) || (e.type === "assistant_message" && e.data.canonical !== true))){
     const spinePage = await getMissionEventPage(id, { before, view: "transcript" }).catch(() => null);
     check();
     if(spinePage?.events?.length){
      const spine = spineAnswers(spinePage.events.map(storedToStream).filter((e): e is StreamEvent => e !== null));
      stream = mergeStreamBySequence(spine, stream);
     }
    }
    break;
   }
   if(page.nextCursor!==undefined){if(page.nextCursor<=cursor)throw Error('Event cursor did not advance.');cursor=page.nextCursor;}
   if(!page.hasMore)break;
   if(++forwardPages>=2){
    // More than 400 raw events streamed since our cached cursor (e.g. a long
    // offscreen tool storm). Jump straight to the newest 200-event tail and
    // hydrate the latest conversational spine below instead of walking dozens
    // of sequential pages.
    stream=[];
    cursor=undefined;
    before=undefined;
    hasOlder=undefined;
   }
  }
  stream=mergeStreamBySequence(preview,stream);
  const queued = await queuedPromise;
  check();
  const queueEvents: StreamEvent[] = queued.map(row => ({ type: "user_message", eventId: row.id, data: { id: row.id, content: row.content, queued: row.inflight !== true } }));
  const retainedLive = previous?.liveTail?.length ? heldAfterHistory(stream, previous.liveTail) : [];
  // History first puts accepted user turns at their actual transcript positions.
  return { items: buildTranscript([...stream, ...retainedLive, ...queueEvents]), stream, ...(retainedLive.length ? { liveTail: retainedLive } : {}), fromLog: true, spineComplete: previous?.spineComplete, queueError, cursor, before, hasOlder };
}

type JobKind='initial'|'refresh'|'older';
const jobs=new Map<string,{tail:Promise<unknown>;pending:Map<JobKind,Promise<TranscriptSnap>>}>();
function transcriptJob(id:string,kind:JobKind,load:()=>Promise<TranscriptSnap>):Promise<TranscriptSnap>{
 const scope=key(id),version=connectionVersion();
 let job=jobs.get(scope);if(!job){job={tail:Promise.resolve(),pending:new Map()};jobs.set(scope,job);}
 const pending=job.pending.get(kind);if(pending)return pending;
 const owner=job;
 const result=owner.tail.catch(()=>{}).then(()=>{if(version!==connectionVersion())throw Error('Connection changed during transcript load.');return load();}).then(snapshot=>{
  if(version!==connectionVersion())throw Error('Connection changed during transcript load.');saveSnapshot(scope,snapshot);dirtyMissions.delete(scope);reconcileWarmSubscriptions();return snapshot;
 }).finally(()=>{owner.pending.delete(kind);if(!owner.pending.size)jobs.delete(scope);});
 owner.tail=result;owner.pending.set(kind,result);return result;
}
export function refreshTranscript(id:string):Promise<TranscriptSnap>{
 const scope=key(id),initial=jobs.get(scope)?.pending.get('initial');
 if(initial&&!peekReadyTranscript(id))return initial;
 return transcriptJob(id,'refresh',()=>fetchTranscript(id));
}
export function loadTranscript(id:string):Promise<TranscriptSnap>{
 const cached=peekReadyTranscript(id);return cached?Promise.resolve(cached):transcriptJob(id,'initial',()=>fetchTranscript(id));
}
// A transcript the cache cannot hold (too large), evicted under LRU pressure,
// or that could not load is not speculatively fetched again at every list
// refresh: that re-read whole event logs of large live fleets every 5 s.
const prefetchPaused=new Map<string,number>();
const PREFETCH_PAUSE_MS=10*60_000,PREFETCH_RETRY_MS=60_000;
export const MAX_LIVE_PREFETCH=8;
onCacheEvict((evictedKey)=>{
 if(evictedKey.endsWith(':tx')&&!active.has(evictedKey)){
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
 while(prefetchActive<4&&prefetchQueue.size){
  const [scope,id]=prefetchQueue.entries().next().value!;
  prefetchQueue.delete(scope);
  if(scope!==key(id)||peekReadyTranscript(id)||jobs.has(scope))continue;
  prefetchActive++;
  void loadTranscript(id).then(()=>{if(!active.has(scope)&&cachePeek(scope)===undefined)prefetchPaused.set(scope,Date.now()+PREFETCH_PAUSE_MS);})
   .catch(()=>{prefetchPaused.set(scope,Date.now()+PREFETCH_RETRY_MS);})
   .finally(()=>{prefetchActive--;pumpPrefetch();});
 }
}
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
  for (const [, sub] of warmSubs) sub.stop();
  warmSubs.clear();
  dirtyMissions.clear();
  recentlyOpened.clear();
}
export function loadOlderTranscript(id:string):Promise<TranscriptSnap>{
 return transcriptJob(id,'older',async()=>{
  const previous=peekReadyTranscript(id);if(!previous)return fetchTranscript(id);
  if(!previous.hasOlder||previous.before===undefined)return previous;
  const page=await getMissionEventPage(id,{before:previous.before});
  if(page.hasMore&&(page.nextCursor===undefined||page.nextCursor>=previous.before))throw Error('Older event cursor did not advance.');
  const older=page.events.map(storedToStream).filter((e):e is StreamEvent=>e!==null);
  const stream=mergeStreamBySequence(older,previous.stream);let items=buildTranscript(stream);
  const preservedUsers: StreamEvent[] = [];
  for(const item of previous.items)if(item.kind==='user'&&item.messageId)preservedUsers.push({type:'user_message',data:{id:item.messageId,content:item.text,queued:item.queued,receipt:item.receipt,attached:item.attached}});
  items = applyStreamEvents(items, preservedUsers);
  return {...previous,stream,items,before:page.nextCursor??previous.before,hasOlder:page.hasMore};
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
    let items = buildTranscript(stream);
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
        });
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
 if(!recentlyOpened.has(scope) || active.has(scope) || isMissionWarmLive(id) || jobs.has(scope) || presentationLoads.has(scope)) return;
 presentationLoads.add(scope);
 try {
 const page=await getMissionEventPreview(id);
 if(scope!==key(id) || active.has(scope) || jobs.has(scope)) return;
 const prior=peekTranscript(id);
 const incoming=spineAnswers(page.events.map(storedToStream).filter((e):e is StreamEvent=>e!==null));
 const stream=mergeStreamBySequence(prior?.stream??[],incoming);
 saveSnapshot(scope,{...prior,activity:page.activity,stream,items:buildTranscript(stream),fromLog:true,detailsPending:prior?.detailsPending ?? !prior?.fromLog});
 } finally { presentationLoads.delete(scope); }
}

export function recordPresentationActivity(id: string, label: unknown) {
 if(typeof label!=="string" || !label) return;
 const scope=key(id), prior=peekTranscript(id);
 if(!recentlyOpened.has(scope) || !prior || active.has(scope)) return;
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
    let items = buildTranscript(stream);
    for (const item of current.items) {
      if (item.kind === "user" && item.messageId) {
        items = applyStreamEvent(items, {
          type: "user_message",
          data: { id: item.messageId, content: item.text, queued: item.queued, receipt: item.receipt, attached: item.attached },
        });
      }
    }
    return { ...current, stream, items, before, hasOlder };
  });
}
