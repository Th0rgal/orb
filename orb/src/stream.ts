import {batch} from "solid-js";
import { api, clearConnection, getJwt, connectionVersion, isAbortError, isTransientNetworkError, noteAbort, orderedApiCandidates, REQUEST_TIMEOUT_MS, RequestTimeoutError, transportFetch } from "./api";
import { nativeInvoke } from "./native";
import { requestDone, streamLoad, timed } from "./diagnostics";
import {
  orbKernelScratchSliceStep,
  orbWireStreamSliceStep,
} from "./orbKernel";

export const STREAM_MAX_OPEN_TAIL_BYTES = 16_384;

export type StreamTailCommitState = {
  totalBytes: number;
  committedBytes: number;
  checkpointBytes: number;
};

const EMPTY_STREAM_TAIL: Uint8Array<ArrayBufferLike> = new Uint8Array(0);
const UTF8_ENCODER = new TextEncoder();

export function advanceStreamBoundedCommit(
  state: StreamTailCommitState,
  chunkBytes: number,
  rawCommitBytes: number,
  maxOpenTailBytes = STREAM_MAX_OPEN_TAIL_BYTES,
  inTailOrByteLen: Uint8Array | number = EMPTY_STREAM_TAIL,
): StreamTailCommitState & { admitted: boolean; checkpointForced: boolean } {
  if (
    !Number.isInteger(chunkBytes) ||
    chunkBytes < 0 ||
    !Number.isInteger(rawCommitBytes) ||
    !Number.isInteger(maxOpenTailBytes) ||
    !Number.isInteger(state.totalBytes) ||
    !Number.isInteger(state.committedBytes) ||
    !Number.isInteger(state.checkpointBytes) ||
    (typeof inTailOrByteLen === "number" && (!Number.isInteger(inTailOrByteLen) || inTailOrByteLen < 0))
  ) {
    return { ...state, admitted: false, checkpointForced: false };
  }
  const newLen = state.totalBytes + chunkBytes;
  const tailByteLen = typeof inTailOrByteLen === "number" ? inTailOrByteLen : inTailOrByteLen.byteLength;
  const scratchInBytes = typeof inTailOrByteLen === "number" ? 0 : Math.min(tailByteLen, STREAM_MAX_OPEN_TAIL_BYTES);
  const scratch = orbKernelScratchSliceStep(scratchInBytes);
  if (typeof inTailOrByteLen !== "number" && scratch.inView.byteLength > 0) {
    scratch.inView.set(inTailOrByteLen.subarray(0, scratch.inView.byteLength));
  }
  const sliceRes = orbWireStreamSliceStep({
    inTail: typeof inTailOrByteLen !== "number" && scratch.inView.byteLength > 0 ? scratch.inView : EMPTY_STREAM_TAIL,
    outBuf: scratch.outView,
    inPtr: tailByteLen === 0 ? 0 : scratch.inOffset,
    outPtr: scratch.outOffset,
    inTailBytesLen: tailByteLen,
    prevLen: state.totalBytes,
    prevCommit: state.committedBytes,
    prevCheckpoint: state.checkpointBytes,
    newLen,
    rawCommit: rawCommitBytes,
    maxOpenTailBytes,
  });
  if (sliceRes.status !== 0 || !sliceRes.verdict || !sliceRes.verdict.admitted) {
    return { ...state, admitted: false, checkpointForced: false };
  }
  const nextCommitted = Math.max(state.committedBytes, Math.min(newLen, rawCommitBytes));
  return {
    totalBytes: newLen,
    committedBytes: nextCommitted,
    checkpointBytes: sliceRes.verdict.nextCheckpoint,
    admitted: true,
    checkpointForced: sliceRes.verdict.checkpointForced,
  };
}

export interface StoredEvent {
  id: number;
  event_id?: string | null;
  sequence: number;
  event_type: string;
  timestamp: string;
  tool_call_id?: string | null;
  tool_name?: string | null;
  content: string;
  metadata?: Record<string, unknown>;
}

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const REMOTE_JOB_RUNNING = new RegExp(`^Remote job ${UUID} on node '[^']+' is now (queued|running|finished)$`);
const DISPATCHED_JOB = new RegExp(`^Dispatched job ${UUID} to remote node '[^']+'(?: \\([^\\n]*\\))?$`);
const PARALLEL_CANCEL_REQUESTED = new RegExp(`^Parallel mission ${UUID} cancellation requested$`, "i");

export function isGeneratedRemoteJobStatus(ev: Pick<StoredEvent, "content" | "metadata">): boolean {
  const meta = ev.metadata ?? {};
  if (meta.kind === "remote_job_status" || meta.remote_job_status === true) return true;
  return REMOTE_JOB_RUNNING.test(ev.content) || DISPATCHED_JOB.test(ev.content);
}

/** Legacy parallel-runner cancellation acknowledgement — not a mission failure. */
export function isCancellationRequestedNotice(text: string): boolean {
  return PARALLEL_CANCEL_REQUESTED.test(text.trim());
}

/** Core marks the persisted text of a turn that was cut (Send now, Stop). */
export const PARTIAL_TURN = "partial_turn_interrupted";
export function isPartialTurn(data: Record<string, unknown> | undefined): boolean {
  const evidence = data?.completion_evidence as { classification_source?: unknown } | undefined;
  return data?.partial === true || evidence?.classification_source === PARTIAL_TURN;
}

export interface StreamEvent {
  eventId?: string;
  sequence?: number;
  storedId?: number;
  type: string;
  data: Record<string, unknown>;
}

async function apiRawOnce(path: string): Promise<Response> {
  const version = connectionVersion();
  const jwt = getJwt();
  const started = performance.now();
  let res: Response;
  try {
    res = await transportFetch(path, {
      headers: jwt ? { Authorization: `Bearer ${jwt}` } : {},
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (error) {
    if (isAbortError(error)) {
      noteAbort(`GET ${path}`, "timeout", performance.now() - started);
      throw new RequestTimeoutError();
    }
    throw error;
  }
  if (connectionVersion() !== version) throw new Error("Connection changed");
  if (res.status === 401) {
    clearConnection();
    throw new Error("401 Unauthorized — reconnect in Settings → Account");
  }
  if (!res.ok) throw new Error(`${res.status} ${await res.text().catch(() => "")}`.trim());
  return res;
}

async function apiRaw(path: string): Promise<Response> {
  const from = performance.now(), label = `GET ${path.slice(0, 160)}`;
  try {
    let res: Response;
    try {
      res = await apiRawOnce(path);
    } catch (error) {
      if (error instanceof RequestTimeoutError || !isTransientNetworkError(error)) throw error;
      await new Promise((resolve) => setTimeout(resolve, 200 + Math.floor(Math.random() * 200)));
      res = await apiRawOnce(path);
    }
    requestDone(label, performance.now() - from, true);
    return res;
  } catch (error) {
    requestDone(label, performance.now() - from, false, error instanceof Error ? error.message : String(error));
    throw error;
  }
}

export interface EventPage { activity?: string; events: StoredEvent[]; nextCursor?: number; pageMax?: number; reset?:boolean; hasMore: boolean }
/** Tool payloads larger than this arrive shortened from event pages. */
export const MAX_EVENT_PAYLOAD=4096;
/** The whole call and result of one tool row, for a row Core shortened. */
export async function fullToolCall(missionId:string,callId:string):Promise<{args?:unknown;result?:unknown}>{
 const rows=await api<StoredEvent[]>(`/api/control/missions/${encodeURIComponent(missionId)}/tool-calls/${encodeURIComponent(callId)}`);
 const out:{args?:unknown;result?:unknown}={};
 for(const row of rows){const event=storedToStream(row);if(event?.type==='tool_call')out.args=event.data.args;else if(event?.type==='tool_result')out.result=event.data.result;}
 return out;
}
export async function getMissionEventPage(id:string, cursor:{since?:number;before?:number;view?:'transcript'|'trace'|'history'|'all';limit?:number}={}):Promise<EventPage>{
 // Large tool outputs arrive shortened; a row loads its full call when opened
 // (fullToolCall). Older Cores ignore the parameter.
 const query=new URLSearchParams({limit:String(cursor.limit??200),include_counts:'false',max_payload:String(MAX_EVENT_PAYLOAD)});
 if(cursor.view)query.set('view',cursor.view);
 if(cursor.since!==undefined)query.set('since_seq',String(cursor.since));
 if(cursor.before!==undefined)query.set('before_seq',String(cursor.before));
 const response=await apiRaw(`/api/control/missions/${id}/events?${query}`);
 const events=await response.json() as StoredEvent[];
 if(!Array.isArray(events)||response.headers.get('X-Orb-Events-Protocol')!=='1'||!response.headers.has('X-Has-More'))throw Error('Invalid event page protocol. Redeploy Orb and the backend together.');
 const number=(name:string)=>{const value=response.headers.get(name);if(value===null)return undefined;const n=Number(value);if(!value.trim()||!Number.isSafeInteger(n)||n<0)throw Error(`Invalid event cursor: ${name}`);return n;};
 const nextCursor=number('X-Next-Cursor'),pageMax=number('X-Page-Max-Sequence'),max=number('X-Max-Sequence'),more=response.headers.get('X-Has-More');
 if(!['true','false'].includes(more!)||((more==='true'||events.length>0)&&(nextCursor===undefined||pageMax===undefined)))throw Error('Incomplete event page cursor.');
 return {events,reset:cursor.since!==undefined&&max!==undefined&&cursor.since>max,nextCursor,pageMax,hasMore:more==='true'};
}
/** First paint needs the newest message, not hundreds of activity payloads. */
export function getMissionEventPreview(id:string):Promise<EventPage>{
 return api<{profile?:string;activity?:string;events:StoredEvent[]}>(`/api/control/missions/${id}/snapshot?profile=presentation`)
  .then(snapshot => {
   if(snapshot.profile!=="presentation" || !Array.isArray(snapshot.events)) throw Error("Presentation profile unavailable");
   return {events:snapshot.events,activity:snapshot.activity,hasMore:true} as EventPage;
  }).catch(()=>getMissionEventPage(id,{view:'transcript',limit:2}));
}
/** The mission's stored events, oldest first, newest last. The endpoint pages
 * 200 rows from the tail, so a single page silently drops older turns of a
 * long thread (a /btw thread easily exceeds it with tool rows). This walks
 * back with the exclusive `before` cursor until the history is complete, or
 * until `enough` says the rows read so far suffice (e.g. the latest turn). */
export async function getMissionEvents(id:string,options:{view?:'transcript'|'trace'|'history'|'all';since?:number;limit?:number;enough?:(newestFirst:StoredEvent[])=>boolean}={}):Promise<StoredEvent[]>{
 const bySequence=new Map<number,StoredEvent>();
 const pageLimit=options.limit!==undefined?{limit:options.limit}:{};
 if(options.since!==undefined){
  let since=options.since,reset=false;
  for(let pages=0;pages<500;pages++){
   const page=await getMissionEventPage(id,{...(options.view?{view:options.view}:{}),...pageLimit,since});
   if(page.reset){reset=true;bySequence.clear();break;}
   for(const event of page.events)bySequence.set(event.sequence,event);
   if(!page.hasMore||page.nextCursor===undefined||!page.events.length)break;
   if(page.nextCursor<=since)throw Error('Event cursor did not advance.');
   since=page.nextCursor;
   if(options.enough?.([...bySequence.values()].sort((a,b)=>b.sequence-a.sequence)))break;
  }
  if(!reset)return [...bySequence.values()].sort((a,b)=>a.sequence-b.sequence);
 }
 let before:number|undefined;
 for(let pages=0;pages<500;pages++){
  const page=await getMissionEventPage(id,{...(options.view?{view:options.view}:{}),...pageLimit,...(before!==undefined?{before}:{})});
  for(const event of page.events)bySequence.set(event.sequence,event);
  if(!page.hasMore||page.nextCursor===undefined||!page.events.length)break;
  if(before!==undefined&&page.nextCursor>=before)throw Error('Event cursor did not advance.');
  before=page.nextCursor;
  if(options.enough?.([...bySequence.values()].sort((a,b)=>b.sequence-a.sequence)))break;
 }
 return [...bySequence.values()].sort((a,b)=>a.sequence-b.sequence);
}

/** Map a stored (replayed) event row onto the live-stream event shape. */
export function storedToStream(ev: StoredEvent): StreamEvent | null {
  const d = (obj: Record<string, unknown>): StreamEvent => ({ type: ev.event_type, data: obj, eventId: ev.event_id ?? undefined, sequence: ev.sequence, storedId: ev.id });
  switch (ev.event_type) {
    case "text_delta":
      return d({ content: ev.content, at: ev.timestamp });
    case "thinking":
      return d({ content: ev.content, done: ev.metadata?.done === true });
    case "user_message":
      return d({ id: ev.event_id ?? undefined, content: ev.content, queued: ev.metadata?.queued === true, source: ev.metadata?.source, messages: ev.metadata?.messages, at: ev.timestamp });
    case "assistant_message":
    case "assistant_message_canonical":
      // Exact generated remote-job status rows, not ordinary assistant prose.
      if (isGeneratedRemoteJobStatus(ev)) return null;
      // Canonical rows are the finalized text_op bubble; treat both as the
      // turn's final message (the reducer dedupes identical text).
      return { ...d({ content: ev.content, success: ev.metadata?.success !== false, completion_evidence: ev.metadata?.completion_evidence, canonical: ev.event_type === "assistant_message_canonical", bubble_id: ev.metadata?.bubble_id, revision: ev.metadata?.revision, ...(isPartialTurn(ev.metadata) ? { partial: true } : {}), at: ev.timestamp }), type: "assistant_message" };
    case "text_op": {
      let ops: unknown = [];
      try {
        ops = JSON.parse(ev.content);
      } catch {
        ops = [];
      }
      return d({ bubble_id: ev.metadata?.bubble_id, ops, at: ev.timestamp });
    }
    case "tool_call": {
      let args: unknown = null;
      try {
        args = JSON.parse(ev.content);
      } catch {
        args = ev.content;
      }
      return d({ tool_call_id: ev.tool_call_id ?? `event-${ev.id}`, name: ev.tool_name ?? "tool", args, ...(ev.metadata?.truncated === true ? { truncated: true } : {}) });
    }
    case "tool_result": {
      let result: unknown = ev.content;
      try {
        result = JSON.parse(ev.content);
      } catch {
        /* plain string */
      }
      return d({ tool_call_id: ev.tool_call_id ?? "", name: ev.tool_name ?? "tool", result, ...(ev.metadata?.truncated === true ? { truncated: true } : {}) });
    }
    case "error":
      if (isCancellationRequestedNotice(ev.content)) return null;
      return d({ message: ev.content, resumable: false });
    case "mission_status_changed":
      return d({ status: ev.metadata?.status, summary: ev.content || undefined });
    default:
      return null;
  }
}

let forceMultiplexSyncForTest = false;
export function setMultiplexSyncEnabledForTest(enabled: boolean): void {
  forceMultiplexSyncForTest = enabled;
  if (!enabled && activeSyncHub) {
    activeSyncHub.destroy();
    activeSyncHub = null;
  }
}

type SyncListener = {
  missionId: string | null;
  getSinceSeq: () => number | undefined;
  deliver: (ev: StreamEvent) => void;
  onLagged: () => void;
  onReady?: () => void;
  onDisconnected?: () => void;
  startFallback: () => void;
};

type MultiplexSyncHub = {
  connVer: number;
  listeners: Set<SyncListener>;
  destroy: () => void;
  refreshSubscriptions: () => void;
};

let activeSyncHub: MultiplexSyncHub | null = null;

function toWsUrl(httpBase: string, path: string): string {
  const clean = httpBase.trim().replace(/\/+$/, "");
  if (clean.startsWith("https://")) return `wss://${clean.slice(8)}${path}`;
  if (clean.startsWith("http://")) return `ws://${clean.slice(7)}${path}`;
  return `${clean}${path}`;
}

function getOrCreateSyncHub(): MultiplexSyncHub | null {
  if (!forceMultiplexSyncForTest && !nativeInvoke()) return null;
  if (typeof WebSocket === "undefined") return null;
  const jwt = getJwt();
  const ver = connectionVersion();
  if (activeSyncHub && activeSyncHub.connVer === ver) return activeSyncHub;
  activeSyncHub?.destroy();

  const listeners = new Set<SyncListener>();
  let socket: WebSocket | null = null;
  let ready = false;
  let closed = false;
  let consecutiveFailures = 0;
  let candidateIdx = 0;
  let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  let pingTimer: ReturnType<typeof setInterval> | undefined;
  let pongTimer: ReturnType<typeof setTimeout> | undefined;
  let idleCloseTimer: ReturnType<typeof setTimeout> | undefined;
  const subscribedOnSocket = new Set<string>();
  let presentationSent: boolean | null = null;

  const clearTimers = () => {
    if (reconnectTimer) clearTimeout(reconnectTimer);
    if (pingTimer) clearInterval(pingTimer);
    if (pongTimer) clearTimeout(pongTimer);
    reconnectTimer = pingTimer = pongTimer = undefined;
  };

  const sendJson = (msg: Record<string, unknown>) => {
    if (socket && socket.readyState === WebSocket.OPEN) {
      try { socket.send(JSON.stringify(msg)); } catch { /* closing */ }
    }
  };

  const syncSubscriptions = () => {
    if (!socket || socket.readyState !== WebSocket.OPEN || !ready) return;
    const wantPresentation = [...listeners].some((l) => l.missionId === null);
    if (presentationSent !== wantPresentation) {
      presentationSent = wantPresentation;
      sendJson({ op: "set_presentation", enabled: wantPresentation });
    }
    const wantedByMission = new Map<string, number | undefined>();
    for (const l of listeners) {
      if (!l.missionId) continue;
      const seq = l.getSinceSeq();
      if (!wantedByMission.has(l.missionId)) {
        wantedByMission.set(l.missionId, seq);
      } else {
        const prev = wantedByMission.get(l.missionId);
        wantedByMission.set(l.missionId, prev !== undefined && seq !== undefined ? Math.min(prev, seq) : undefined);
      }
    }
    for (const mid of [...subscribedOnSocket]) {
      if (!wantedByMission.has(mid)) {
        subscribedOnSocket.delete(mid);
        sendJson({ op: "unsubscribe", mission_id: mid });
      }
    }
    for (const [mid, sinceSeq] of wantedByMission) {
      if (!subscribedOnSocket.has(mid)) {
        subscribedOnSocket.add(mid);
        sendJson({ op: "subscribe", mission_id: mid, ...(sinceSeq !== undefined ? { since_seq: sinceSeq } : {}) });
      }
    }
  };

  const triggerFallbackAll = () => {
    closed = true;
    clearTimers();
    if (socket) { try { socket.close(); } catch { /* ignore */ } socket = null; }
    if (activeSyncHub === hub) activeSyncHub = null;
    for (const l of [...listeners]) {
      listeners.delete(l);
      l.startFallback();
    }
  };

  const openSocket = () => {
    if (closed || !listeners.size) return;
    if (connectionVersion() !== ver) {
      hub.destroy();
      return;
    }
    const candidates = orderedApiCandidates();
    if (!candidates.length) {
      triggerFallbackAll();
      return;
    }
    const base = candidates[candidateIdx % candidates.length];
    const token = getJwt();
    const protocols = token ? ["orb-sync.v1", `jwt.${token}`] : ["orb-sync.v1"];
    let ws: WebSocket;
    try {
      ws = new WebSocket(toWsUrl(base, "/api/control/sync"), protocols);
    } catch {
      triggerFallbackAll();
      return;
    }
    socket = ws;
    ready = false;
    subscribedOnSocket.clear();
    presentationSent = null;

    const connectDeadline = setTimeout(() => {
      if (socket === ws && !ready) {
        try { ws.close(); } catch { /* ignore */ }
      }
    }, 5_000);

    ws.onopen = () => {
      if (socket !== ws || closed) return;
      clearTimeout(connectDeadline);
      ready = true;
      const hadFailures = consecutiveFailures > 0;
      consecutiveFailures = 0;
      syncSubscriptions();
      for (const l of listeners) {
        if (l.onReady) l.onReady();
        else if (hadFailures) l.onLagged();
      }
      pingTimer = setInterval(() => {
        if (socket !== ws || ws.readyState !== WebSocket.OPEN) return;
        sendJson({ op: "ping", ts: Date.now() });
        if (!pongTimer) {
          pongTimer = setTimeout(() => {
            pongTimer = undefined;
            if (socket === ws) {
              try { ws.close(); } catch { /* ignore */ }
            }
          }, 5_000);
        }
      }, 10_000);
    };

    ws.onmessage = (msg) => {
      if (socket !== ws || typeof msg.data !== "string") return;
      if (pongTimer) {
        clearTimeout(pongTimer);
        pongTimer = undefined;
      }
      let parsed: Record<string, unknown>;
      try {
        parsed = JSON.parse(msg.data) as Record<string, unknown>;
      } catch {
        return;
      }
      const eventType = typeof parsed.type === "string" ? parsed.type : "";
      if (!eventType || eventType === "sync_ready" || eventType === "heartbeat" || eventType === "pong" || eventType === "subscribed" || eventType === "unsubscribed") {
        return;
      }
      streamLoad("sync-ws", 1, msg.data.length);
      if (eventType === "stream_lagged") {
        const targetMid = typeof parsed.mission_id === "string" ? parsed.mission_id : null;
        for (const l of listeners) {
          if (!targetMid || l.missionId === targetMid) l.onLagged();
        }
        return;
      }
      if (eventType === "mission_presentation") {
        const ev: StreamEvent = { type: "mission_presentation", data: parsed };
        for (const l of listeners) {
          if (l.missionId === null) l.deliver(ev);
        }
        return;
      }
      if (eventType === "assistant_message" && isPartialTurn(parsed)) parsed.partial = true;
      if (eventType === "assistant_message" && typeof parsed.at !== "string") parsed.at = new Date().toISOString();
      const targetMid = typeof parsed.mission_id === "string" ? parsed.mission_id : null;
      const ev: StreamEvent = {
        type: eventType,
        data: parsed,
        eventId: (parsed.event_id ?? parsed.id) as string | undefined,
        sequence: typeof parsed.sequence === "number" ? parsed.sequence : undefined,
      };
      for (const l of listeners) {
        if (!l.missionId) continue;
        if (!targetMid || l.missionId === targetMid) l.deliver(ev);
      }
    };

    const handleDisconnect = () => {
      if (socket !== ws) return;
      clearTimeout(connectDeadline);
      clearTimers();
      socket = null;
      const wasReady = ready;
      ready = false;
      for (const l of listeners) l.onDisconnected?.();
      if (closed || !listeners.size) return;
      consecutiveFailures++;
      candidateIdx++;
      // If we never managed to complete handshake across all candidates, fall back cleanly to SSE.
      if (!wasReady && consecutiveFailures >= Math.max(2, candidates.length)) {
        triggerFallbackAll();
        return;
      }
      if (wasReady) {
        for (const l of listeners) if (l.getSinceSeq() === undefined) l.onLagged();
      }
      const delay = Math.min(400 * 2 ** Math.min(consecutiveFailures - 1, 5), 10_000);
      reconnectTimer = setTimeout(openSocket, delay);
    };

    ws.onerror = () => { /* onclose handles state transition */ };
    ws.onclose = handleDisconnect;
  };

  const hub: MultiplexSyncHub = {
    connVer: ver,
    listeners,
    refreshSubscriptions() {
      if (idleCloseTimer) {
        clearTimeout(idleCloseTimer);
        idleCloseTimer = undefined;
      }
      if (!listeners.size) {
        idleCloseTimer = setTimeout(() => {
          if (!listeners.size) hub.destroy();
        }, 5_000);
        return;
      }
      if (!socket && !reconnectTimer && !closed) openSocket();
      else syncSubscriptions();
    },
    destroy() {
      closed = true;
      clearTimers();
      if (idleCloseTimer) clearTimeout(idleCloseTimer);
      if (socket) { try { socket.close(); } catch { /* ignore */ } socket = null; }
      listeners.clear();
      if (activeSyncHub === hub) activeSyncHub = null;
    },
  };

  if (jwt || forceMultiplexSyncForTest) {
    activeSyncHub = hub;
    return hub;
  }
  return null;
}

/**
 * Subscribe to the mission's live event stream:
 * - On Orb desktop (`__TAURI__`), multiplexes both presentation hints and all
 *   per-mission subscriptions onto a single heartbeat-monitored WebSocket
 *   (`/api/control/sync`), automatically falling back to `/api/control/stream`
 *   SSE if WebSocket upgrade is unavailable.
 * - Reconnects with `since_seq` replay and backoff until cleanup is called.
 */
export function streamMission(
  missionId: string | null,
  onEvent: (ev: StreamEvent) => void,
  onLagged: () => void,
  onReady?:()=>void,
  profile?: "presentation",
  onBatch?: (evs: StreamEvent[]) => void,
  onDisconnected?: () => void,
): () => void {
  let stopped = false;
  let highestSeq: number | undefined;
  let fragments:StreamEvent[]=[],paint:ReturnType<typeof setTimeout>|undefined;
  const flush=()=>{clearTimeout(paint);paint=undefined;const pending=fragments;fragments=[];if(pending.length)timed('stream text',()=>batch(()=>{if(onBatch)onBatch(pending);else for(const event of pending)onEvent(event);}));};
  // Thinking deltas carry the whole thought so far; applied one by one each
  // re-renders a growing block (up to 70 ms each on a long thought). They are
  // painted together with text, once per frame.
  const deliver=(event:StreamEvent)=>{if(typeof event.sequence==="number"&&Number.isSafeInteger(event.sequence))highestSeq=highestSeq===undefined?event.sequence:Math.max(highestSeq,event.sequence);if(event.type==='text_delta'||event.type==='text_op'||(event.type==='thinking'&&event.data.done!==true)){fragments.push(event);paint??=setTimeout(flush,16);}else{flush();timed(`stream ${event.type}`,()=>onEvent(event));}};
  let retry = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let controller: AbortController | undefined;
  let detachSyncListener: (() => void) | undefined;

  const connect = async () => {
    if (stopped) return;
    controller = new AbortController();
    try {
      const jwt = getJwt();
      const params = new URLSearchParams(
        missionId
          ? { mission: missionId, ...(highestSeq !== undefined ? { since_seq: String(highestSeq) } : {}) }
          : { profile: profile ?? "presentation", kinds: "mission_presentation" },
      );
      const res = await transportFetch(`/api/control/stream?${params}`, {
        headers: {
          Accept: "text/event-stream",
          ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}),
        },
        signal: controller.signal,
      });
      if (res.status === 401) {
        // Token expired/revoked: reconnecting would loop forever.
        clearConnection();
        stopped = true;
        return;
      }
      if (!res.ok || !res.body) throw new Error(`stream ${res.status}`);
      if (profile === "presentation" && !res.headers.get("Content-Type")?.includes("text/event-stream")) throw new Error("Presentation stream unavailable");
      if(onReady)onReady();
      else if (retry > 0) {
        // Events emitted while we were disconnected never reached us.
        onLagged();
      }
      retry = 0;
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let tailState: StreamTailCommitState = { totalBytes: 0, committedBytes: 0, checkpointBytes: 0 };
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        const decoded = decoder.decode(value, { stream: true }).replace(/\r\n/g, "\n").replace(/\r/g, "\n");
        const decodedUtf8Len = UTF8_ENCODER.encode(decoded).byteLength;
        buffer += decoded;
        let idx = buffer.indexOf("\n\n"), frames = 0, consumedBytes = 0;
        while (idx !== -1) {
          const raw = buffer.slice(0, idx);
          buffer = buffer.slice(idx + 2);
          consumedBytes += UTF8_ENCODER.encode(raw).byteLength + 2;
          idx = buffer.indexOf("\n\n");
          let eventType = "message";
          let data = "";
          for (const line of raw.split("\n")) {
            if (line.startsWith("event:")) eventType = line.slice(6).trim();
            else if (line.startsWith("data:")) data += line.slice(5).trim();
          }
          if (!data) continue;
          frames++;
          if (eventType === "stream_lagged") {
            onLagged();
            continue;
          }
          try {
            const parsed = JSON.parse(data);
            if (eventType === "assistant_message" && isPartialTurn(parsed)) parsed.partial = true;
            // Live rows carry no stored timestamp: arrival is when the turn completed.
            if (eventType === "assistant_message" && typeof parsed.at !== "string") parsed.at = new Date().toISOString();
            deliver({ type: eventType, data: parsed, eventId: parsed.event_id ?? parsed.id, sequence: parsed.sequence });
          } catch {
            /* malformed frame — skip */
          }
        }
        const openTailBytes = buffer.length > 0 ? UTF8_ENCODER.encode(buffer) : EMPTY_STREAM_TAIL;
        tailState = advanceStreamBoundedCommit(
          tailState,
          decodedUtf8Len,
          tailState.committedBytes + consumedBytes,
          STREAM_MAX_OPEN_TAIL_BYTES,
          openTailBytes,
        );
        streamLoad(`mission ${missionId?.slice(0, 8) ?? "presentation"}`, frames, value.byteLength);
      }
      flush();
      throw new Error("stream ended");
    } catch (e) {
      if (stopped || (e instanceof DOMException && e.name === "AbortError")) return;
      onDisconnected?.();
      if(retry===0)onLagged();
      retry = Math.min(retry + 1, 5);
      timer = setTimeout(() => void connect(), Math.min(1000 * 2 ** retry, 15000));
    }
  };

  const syncHub = getOrCreateSyncHub();
  if (syncHub) {
    const listener: SyncListener = {
      missionId,
      getSinceSeq: () => highestSeq,
      deliver,
      onLagged,
      onReady,
      onDisconnected,
      startFallback: () => {
        detachSyncListener = undefined;
        if (!stopped) void connect();
      },
    };
    syncHub.listeners.add(listener);
    syncHub.refreshSubscriptions();
    detachSyncListener = () => {
      syncHub.listeners.delete(listener);
      syncHub.refreshSubscriptions();
    };
  } else {
    void connect();
  }

  return () => {
    stopped = true;
    detachSyncListener?.();
    detachSyncListener = undefined;
    clearTimeout(paint);fragments=[];
    if (timer) clearTimeout(timer);
    controller?.abort();
  };
}

/** Trim only overlap proven by event identity/sequence or a tool boundary.
 * Text contents are deliberately never an identity: two real replies may match. */
export function heldAfterHistory(history: StreamEvent[], held: StreamEvent[]): StreamEvent[] {
  const identity = (event: StreamEvent): string | undefined => {
    // Mutable snapshots reuse a row ID; only the same revision overlaps.
    if (event.sequence != null) return `sequence:${event.sequence}:${event.type}`;
    const id = event.eventId ?? event.data.id;
    if (id != null) return `${event.type}:${id}`;
    if ((event.type === "tool_call" || event.type === "tool_result") && event.data.tool_call_id)
      return `${event.type}:${event.data.tool_call_id}`;
    return undefined;
  };
  const known = new Set(history.map(identity).filter(Boolean));
  const revisions = new Map<string, number>();
  for (const event of history) {
    const eventId=event.eventId ?? event.data.id;
    if(eventId != null && event.type !== 'text_delta' && event.type !== 'text_op') known.add(`${event.type}:${eventId}`);
    if (event.type === "tool_call" || event.type === "tool_result") known.add(`${event.type}:${event.data.tool_call_id}`);
    const bubble = String(event.data.bubble_id ?? "");
    if (event.type === 'assistant_message' && event.data.canonical === true && typeof event.data.revision === 'number') revisions.set(bubble, Math.max(revisions.get(bubble) ?? 0, event.data.revision));
    if (event.type === 'text_op' && Array.isArray(event.data.ops)) for (const op of event.data.ops) {
      if (op.type === 'snapshot' && typeof op.revision === 'number') revisions.set(bubble, Math.max(revisions.get(bubble) ?? 0, op.revision));
    }
  }
  // Messages the history already shows as delivered. Everything streamed live
  // before one of them belongs to an earlier turn, which the history now owns:
  // replaying it after the snapshot would append that turn's text a second time
  // below the newer message (the doubled "step N done" after a Send now).
  const delivered = new Set<string>();
  for (const event of history) {
    const id = event.eventId ?? event.data.id;
    if (event.type === 'user_message' && event.data.queued !== true && id != null) delivered.add(String(id));
  }
  // The stored text_delta row is the current turn's text. When history
  // already holds it, held live text of that same turn (everything before
  // the first message history has not delivered yet) is a second copy: the
  // replay after a Send now interrupt rendered "step 1…5 done" twice.
  const latestText = (event: StreamEvent) => event.type === 'text_delta' || (event.type === 'text_op' && String(event.data.bubble_id ?? 'text_delta_latest') === 'text_delta_latest');
  let lastHistoryUser = -1;
  history.forEach((event, index) => { if (event.type === 'user_message' && event.data.queued !== true) lastHistoryUser = index; });
  const turnText = history.slice(lastHistoryUser + 1).filter(latestText);
  const historyHasTurnText = turnText.length > 0;
  // A sequenced revision newer than the stored row is newer text, not a copy.
  const storedThrough = Math.max(-1, ...turnText.map(event => event.sequence ?? -1));
  let newTurn = held.findIndex(event => event.type === 'user_message' && event.data.queued !== true && !delivered.has(String(event.data.id ?? event.eventId)));
  if (newTurn < 0) newTurn = held.length;
  let finalizedThrough = -1;
  held.forEach((event,index) => {
    const key=identity(event);
    if(event.type === 'assistant_message' && event.data.canonical !== true && key && known.has(key)) finalizedThrough=index;
    if(event.type === 'user_message' && event.data.queued !== true && delivered.has(String(event.data.id ?? event.eventId))) finalizedThrough=index;
  });
  return held.filter((event,index) => {
    if (event.type === 'user_message') return true;
    const key=identity(event);
    if(key && known.has(key)) return false;
    const bubble=String(event.data.bubble_id ?? 'text_delta_latest');
    if(historyHasTurnText && index < newTurn && latestText(event) && (event.sequence == null || event.sequence <= storedThrough)) return false;
    if(index <= finalizedThrough && (event.type==='thinking'||event.type==='text_delta'||(event.type==='text_op'&&bubble==='text_delta_latest'))) return false;
    if(event.type==='text_op'&&Array.isArray(event.data.ops)&&event.data.ops.some(op=>op.type==='snapshot')) {
      const revision=Math.max(...event.data.ops.filter(op=>op.type==='snapshot').map(op=>Number(op.revision)));
      if(revision <= (revisions.get(bubble) ?? -1)) return false;
    }
    // A persisted tool confirms only itself, never the text preceding it.
    return true;
  });
}
