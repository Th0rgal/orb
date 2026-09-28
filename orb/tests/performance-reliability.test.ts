import {afterEach, beforeEach, expect, it, vi} from 'vitest';
import {cacheLoad, cachePut, cachePeek, cacheReset, cacheStats, estimateCacheBytes, cachePrefetch} from '../src/pageCache';
import {sharedRead, invalidateReads} from '../src/sharedReads';
import {pollWhileVisible} from '../src/poll';
const deferred = <T>() => { let resolve!: (value:T)=>void; const promise = new Promise<T>(r=>resolve=r); return {promise,resolve}; };
beforeEach(()=>{cacheReset();invalidateReads();});
afterEach(()=>{vi.useRealTimers();vi.restoreAllMocks();});
it('bounds cached payloads by bytes as well as entry count',()=>{
 const big='x'.repeat(6*1024*1024);
 for(let i=0;i<10;i++)cachePut(String(i),big);
 expect(cacheStats().estimatedBytes).toBeLessThanOrEqual(cacheStats().budgetBytes);
 expect(cacheStats().entries).toBeLessThan(10);
 expect(cachePeek('0')).toBeUndefined();expect(cachePeek('9')).toBe(big);
 const cyclic:any={};cyclic.self=cyclic;expect(estimateCacheBytes(cyclic)).toBeLessThan(100);
});
it('a reset rejects old replies and old cleanup cannot erase a new request',async()=>{
 const a=deferred<string>(),b=deferred<string>();
 const old=cacheLoad('same',()=>a.promise);const rejected=expect(old).rejects.toThrow('Connection changed');
 cacheReset();const current=cacheLoad('same',()=>b.promise);
 a.resolve('old');await rejected;
 const unexpected=vi.fn(async()=> 'wrong');const joined=cacheLoad('same',unexpected);
 b.resolve('new');expect(await joined).toBe('new');expect(unexpected).not.toHaveBeenCalled();await current;expect(cachePeek('same')).toBe('new');
});
it('shares reads only while in flight and respects invalidation',async()=>{
 const a=deferred<number>();const load=vi.fn(()=>a.promise);
 const first=sharedRead('resource',load);expect(sharedRead('resource',load)).toBe(first);
 invalidateReads();const second=sharedRead('resource',()=>Promise.resolve(2));
 a.resolve(1);expect(await first).toBe(1);expect(await second).toBe(2);expect(load).toHaveBeenCalledTimes(1);
 expect(await sharedRead('resource',()=>Promise.resolve(3))).toBe(3);
});
it('serializes prefetch, survives rejection and ignores queued jobs after reset',async()=>{
 vi.useFakeTimers();const gate=deferred<void>();const work=vi.fn(()=>gate.promise),next=vi.fn(async()=>{});
 cachePrefetch('a',work);cachePrefetch('b',next);
 await vi.advanceTimersByTimeAsync(200);expect(work).toHaveBeenCalledTimes(1);expect(next).not.toHaveBeenCalled();
 cacheReset();gate.resolve();await vi.advanceTimersByTimeAsync(200);expect(next).not.toHaveBeenCalled();
 cachePrefetch('c',async()=>{throw new Error('offline')});cachePrefetch('d',next);
 await vi.advanceTimersByTimeAsync(200);expect(next).toHaveBeenCalledTimes(1);
});
it('visible polling skips overlap, recovers from errors and stops cleanly',async()=>{
 vi.useFakeTimers();const gate=deferred<void>();const work=vi.fn().mockImplementationOnce(()=>gate.promise).mockRejectedValueOnce(new Error('offline')).mockResolvedValue(undefined);
 const stop=pollWhileVisible(work,100);
 await vi.advanceTimersByTimeAsync(500);expect(work).toHaveBeenCalledTimes(1);
 gate.resolve();await vi.advanceTimersByTimeAsync(300);expect(work.mock.calls.length).toBeGreaterThan(2);
 stop();const calls=work.mock.calls.length;await vi.advanceTimersByTimeAsync(500);expect(work).toHaveBeenCalledTimes(calls);
});

it('batch replay equals sequential replay including duplicates and tool boundaries',async()=>{
 const {buildTranscript,applyStreamEvent,applyStreamEvents}=await import('../src/transcriptModel');
 const events=[{type:'user_message',eventId:'u',data:{id:'u',content:'Question'}},...Array.from({length:100},(_,i)=>({type:'text_delta',eventId:`d${i}`,data:{content:'x'}})),{type:'tool_call',eventId:'call',data:{tool_call_id:'t',name:'read',args:{path:'a'}}},{type:'tool_result',eventId:'result',data:{tool_call_id:'t',result:'ok'}}];
 let sequential=buildTranscript([]);for(const event of events)sequential=applyStreamEvent(sequential,event);
 const batch=applyStreamEvents(buildTranscript([]),events);
 expect(batch).toEqual(sequential);expect(applyStreamEvents(batch,events)).toEqual(batch);
});

it('a fresh consumer sees a shared request failure while a stale-tolerant consumer retains the cache',async()=>{
 cachePut('failure','cached');
 let fail!:(error:Error)=>void;const gate=new Promise<string>((_,reject)=>fail=reject);
 const stale=cacheLoad('failure',()=>gate);
 const fresh=cacheLoad('failure',async()=> 'unexpected',false);
 const rejected=expect(fresh).rejects.toThrow('offline');fail(new Error('offline'));
 expect(await stale).toBe('cached');await rejected;
});
it('an earlier fetch cannot overwrite a newer direct cache publication',async()=>{
 const gate=deferred<string>();const pending=cacheLoad('live',()=>gate.promise);
 cachePut('live','newer');gate.resolve('earlier');await pending;
 expect(cachePeek('live')).toBe('newer');
});

it('bounds the live paging journal without altering displayed events and resumes after a durable replay',async()=>{
 const {ReplayBuffer}=await import('../src/replayBuffer');const buffer=new ReplayBuffer(1024,2);
 const event={type:'text_delta',data:{content:'text'}};
 buffer.push([event,event]);expect(buffer.available).toBe(true);
 buffer.push([event]);expect(buffer.available).toBe(false);expect(buffer.events).toEqual([]);
 buffer.reset();buffer.push([event]);expect(buffer.available).toBe(true);expect(buffer.events).toEqual([event]);
 buffer.push([{type:'text_delta',data:{content:'x'.repeat(1024)}}]);expect(buffer.available).toBe(false);
});
