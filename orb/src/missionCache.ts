import { connectionVersion, listQueuedMessages } from "./api";
import { applyStreamEvent, buildTranscript, type StreamItem } from "./transcriptModel";
import { getMissionEventPage, storedToStream, type StreamEvent } from "./stream";
import { cacheDelete, cachePeek, cachePut } from "./pageCache";

export type TranscriptSnap = { items: StreamItem[]; stream: StreamEvent[]; fromLog?: boolean; queueError?: string; cursor?: number; before?: number; hasOlder?: boolean };

const key = (id: string) => `c:${connectionVersion()}:m:${id}:tx`;
const heightKey = (id: string) => `c:${connectionVersion()}:m:${id}:h`;

const active=new Map<string,{refs:number;snapshot?:TranscriptSnap}>();
function saveSnapshot(scope:string,snapshot:TranscriptSnap){const entry=active.get(scope);if(entry)entry.snapshot=snapshot;else cachePut(scope,snapshot);}
export function retainTranscript(id:string):()=>void{
 const scope=key(id);let entry=active.get(scope);
 if(entry)entry.refs++;else{entry={refs:1,snapshot:cachePeek<TranscriptSnap>(scope)};cacheDelete(scope);active.set(scope,entry);}
 return()=>{if(--entry.refs===0){active.delete(scope);if(entry.snapshot)cachePut(scope,entry.snapshot);}};
}
export function peekTranscript(id: string): TranscriptSnap | undefined {
  return active.get(key(id))?.snapshot??cachePeek<TranscriptSnap>(key(id));
}

/** Full event-log snapshot, safe to paint on first open. Live SSE patches are not. */
export function peekReadyTranscript(id: string): TranscriptSnap | undefined {
  const snap = peekTranscript(id);
  return snap?.fromLog ? snap : undefined;
}

export function peekTranscriptHeight(id: string): number | undefined {
  return cachePeek<number>(heightKey(id));
}

export function putTranscript(id: string, snap: TranscriptSnap) {
  saveSnapshot(key(id), { ...snap, fromLog: snap.fromLog !== false });
}

export function putTranscriptItems(id: string, items: StreamItem[]) {
  const prev = peekTranscript(id);
  // A log snapshot stays the reopen first-paint. Live deltas update the
  // mounted view only; overwriting here is what flashed mashed SSE text.
  if (prev?.fromLog) return;
  saveSnapshot(key(id), { items, stream: prev?.stream ?? [], fromLog: false });
}

export function putTranscriptHeight(id: string, height: number) {
  if (height > 0) cachePut(heightKey(id), Math.round(height));
}

async function fetchTranscript(id: string): Promise<TranscriptSnap> {
  const version=connectionVersion();const check=()=>{if(version!==connectionVersion())throw Error("Connection changed during transcript load.");};
  // Read pending first, then delivered history. Any delivery racing this read
  // wins by message identity in the reducer; held SSE fills the live boundary.
  let queueError: string | undefined;
  const queued = await listQueuedMessages(id).catch(error => {
    queueError = `Queued messages could not refresh: ${error instanceof Error ? error.message : String(error)}`;
    return [];
  });
  check();
  const previous=peekReadyTranscript(id);
  const stream:StreamEvent[]=[...(previous?.stream??[])];
  let cursor=previous?.cursor, before=previous?.before, hasOlder=previous?.hasOlder;
  let resets=0;
  for(;;){
   const page=await getMissionEventPage(id,cursor===undefined?{}:{since:cursor});
   check();
   if(page.reset){if(resets++)throw Error('Event history changed repeatedly during recovery.');stream.length=0;cursor=undefined;before=undefined;hasOlder=undefined;continue;}
   for(const row of page.events){const event=storedToStream(row);if(event)stream.push(event);}
   if(cursor===undefined){before=page.nextCursor;hasOlder=page.hasMore;cursor=page.pageMax??0;break;}
   if(page.nextCursor!==undefined){if(page.nextCursor<=cursor)throw Error('Event cursor did not advance.');cursor=page.nextCursor;}
   if(!page.hasMore)break;
  }
  const queueEvents: StreamEvent[] = queued.map(row => ({ type: "user_message", eventId: row.id, data: { id: row.id, content: row.content, queued: row.inflight !== true } }));
  // History first puts accepted user turns at their actual transcript positions.
  return { items: buildTranscript([...stream, ...queueEvents]), stream, fromLog: true, queueError, cursor, before, hasOlder };
}

type JobKind='initial'|'refresh'|'older';
const jobs=new Map<string,{tail:Promise<unknown>;pending:Map<JobKind,Promise<TranscriptSnap>>}>();
function transcriptJob(id:string,kind:JobKind,load:()=>Promise<TranscriptSnap>):Promise<TranscriptSnap>{
 const scope=key(id),version=connectionVersion();
 let job=jobs.get(scope);if(!job){job={tail:Promise.resolve(),pending:new Map()};jobs.set(scope,job);}
 const pending=job.pending.get(kind);if(pending)return pending;
 const owner=job;
 const result=owner.tail.catch(()=>{}).then(()=>{if(version!==connectionVersion())throw Error('Connection changed during transcript load.');return load();}).then(snapshot=>{
  if(version!==connectionVersion())throw Error('Connection changed during transcript load.');saveSnapshot(scope,snapshot);return snapshot;
 }).finally(()=>{owner.pending.delete(kind);if(!owner.pending.size)jobs.delete(scope);});
 owner.tail=result;owner.pending.set(kind,result);return result;
}
export function refreshTranscript(id:string):Promise<TranscriptSnap>{return transcriptJob(id,'refresh',()=>fetchTranscript(id));}
export function loadTranscript(id:string):Promise<TranscriptSnap>{
 const cached=peekReadyTranscript(id);return cached?Promise.resolve(cached):transcriptJob(id,'initial',()=>fetchTranscript(id));
}
// A transcript the cache cannot hold (too large) or could not load is not
// fetched again at every list refresh: that re-read whole event logs of large
// live missions every 5 s.
const prefetchPaused=new Map<string,number>();
const PREFETCH_PAUSE_MS=10*60_000,PREFETCH_RETRY_MS=60_000;
export function prefetchTranscript(id:string){
 const scope=key(id);
 if(peekReadyTranscript(id)||jobs.has(scope))return;
 const until=prefetchPaused.get(scope);if(until!==undefined&&until>Date.now())return;
 void loadTranscript(id).then(()=>{if(!active.has(scope)&&cachePeek(scope)===undefined)prefetchPaused.set(scope,Date.now()+PREFETCH_PAUSE_MS);})
  .catch(()=>{prefetchPaused.set(scope,Date.now()+PREFETCH_RETRY_MS);});
}
export function forgetPrefetchPauses(){prefetchPaused.clear();}
export function loadOlderTranscript(id:string):Promise<TranscriptSnap>{
 return transcriptJob(id,'older',async()=>{
  const previous=peekReadyTranscript(id);if(!previous)return fetchTranscript(id);
  if(!previous.hasOlder||previous.before===undefined)return previous;
  const page=await getMissionEventPage(id,{before:previous.before});
  if(page.hasMore&&(page.nextCursor===undefined||page.nextCursor>=previous.before))throw Error('Older event cursor did not advance.');
  const older=page.events.map(storedToStream).filter((e):e is StreamEvent=>e!==null);
  const stream=[...older,...previous.stream];let items=buildTranscript(stream);
  for(const item of previous.items)if(item.kind==='user'&&item.messageId)items=applyStreamEvent(items,{type:'user_message',data:{id:item.messageId,content:item.text,queued:item.queued,receipt:item.receipt,attached:item.attached}});
  return {...previous,stream,items,before:page.nextCursor??previous.before,hasOlder:page.hasMore};
 });
}
