import { connectionVersion, listQueuedMessages } from "./api";
import { buildTranscript, type StreamItem } from "./transcriptModel";
import { getMissionEvents, storedToStream, type StreamEvent } from "./stream";
import { cacheBusy, cacheLoad, cachePeek, cachePut, cachePrefetch } from "./pageCache";

export type TranscriptSnap = { items: StreamItem[]; stream: StreamEvent[]; fromLog?: boolean; queueError?: string; oldestSequence?: number; hasMore?: boolean };

const key = (id: string) => `m:${id}:tx`;
const heightKey = (id: string) => `m:${id}:h`;

export function peekTranscript(id: string): TranscriptSnap | undefined {
  return cachePeek<TranscriptSnap>(key(id));
}

/** Full event-log snapshot, safe to paint on first open. Live SSE patches are not. */
export function peekReadyTranscript(id: string): TranscriptSnap | undefined {
  const snap = peekTranscript(id);
  return snap?.fromLog && snap.items.length ? snap : undefined;
}

export function peekTranscriptHeight(id: string): number | undefined {
  return cachePeek<number>(heightKey(id));
}

export function putTranscript(id: string, snap: TranscriptSnap) {
  cachePut(key(id), { ...snap, fromLog: snap.fromLog !== false });
}

export function putTranscriptItems(id: string, items: StreamItem[]) {
  const prev = peekTranscript(id);
  // A log snapshot stays the reopen first-paint. Live deltas update the
  // mounted view only; overwriting here is what flashed mashed SSE text.
  if (prev?.fromLog) return;
  cachePut(key(id), { items, stream: prev?.stream ?? [], fromLog: false });
}

export function putTranscriptHeight(id: string, height: number) {
  if (height > 0) cachePut(heightKey(id), Math.round(height));
}

const PAGE_SIZE = 1000;

async function fetchTranscript(id: string): Promise<TranscriptSnap> {
  // Read pending first, then delivered history. Any delivery racing this read
  // wins by message identity in the reducer; held SSE fills the live boundary.
  let queueError: string | undefined;
  const queued = await listQueuedMessages(id).catch(error => {
    queueError = `Queued messages could not refresh: ${error instanceof Error ? error.message : String(error)}`;
    return [];
  });
  const events = await getMissionEvents(id, {limit: PAGE_SIZE});
  const first = events[0]?.sequence;
  const previous = peekTranscript(id);
  const stream: StreamEvent[] = first == null ? [] : (previous?.stream ?? []).filter(event => event.sequence != null && event.sequence < first);
  for (const row of events) {
    const ev = storedToStream(row);
    if (ev) stream.push(ev);
  }
  const queueEvents: StreamEvent[] = queued.map(row => ({ type: "user_message", eventId: row.id, data: { id: row.id, content: row.content, queued: row.inflight !== true } }));
  // History first puts accepted user turns at their actual transcript positions.
  return { items: buildTranscript([...stream, ...queueEvents]), stream, fromLog: true, queueError,
    oldestSequence: stream.find(event => event.sequence != null)?.sequence ?? first,
    hasMore: previous?.oldestSequence != null && first != null && previous.oldestSequence < first ? previous.hasMore : first != null && first > 1 };
}

export async function refreshTranscript(id: string): Promise<TranscriptSnap> {
  return cacheLoad(key(id), () => fetchTranscript(id), false);
}

export function loadTranscript(id: string): Promise<TranscriptSnap> {
  return cacheLoad(key(id), () => fetchTranscript(id));
}

export function prefetchTranscript(id: string) {
  if (peekReadyTranscript(id) || cacheBusy(key(id))) return;
  cachePrefetch(key(id), () => loadTranscript(id));
}

/** Older pages are composed off-screen; the caller owns scroll anchoring and live replay. */
export async function olderTranscript(id: string, snapshot: TranscriptSnap): Promise<TranscriptSnap> {
  if (!snapshot.hasMore || snapshot.oldestSequence == null) return snapshot;
  const version = connectionVersion();
  const rows = await getMissionEvents(id, {limit: PAGE_SIZE, beforeSequence: snapshot.oldestSequence});
  if (connectionVersion() !== version) throw new Error("Connection changed");
  const older = rows.filter(row => row.sequence < snapshot.oldestSequence!).map(storedToStream).filter((row): row is StreamEvent => row != null);
  const stream = [...older, ...snapshot.stream];
  const queued: StreamEvent[] = snapshot.items.flatMap(item => item.kind === 'user' && item.queued ? [{type:'user_message',data:{id:item.messageId,content:item.text,queued:true}}] : []);
  return {...snapshot, stream, items:buildTranscript([...stream, ...queued]), oldestSequence:rows[0]?.sequence ?? snapshot.oldestSequence,
    hasMore:rows.length > 0 && rows[0]?.sequence > 1 && rows[0]?.sequence < snapshot.oldestSequence};
}
