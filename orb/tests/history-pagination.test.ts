import {beforeEach, expect, it, vi} from 'vitest';
vi.mock('../src/api',()=>({connectionVersion:()=>0,listQueuedMessages:vi.fn(async()=>[])}));
vi.mock('../src/stream',async original=>({...await original<typeof import('../src/stream')>(),getMissionEventPage:vi.fn()}));
import {getMissionEventPage, type StoredEvent} from '../src/stream';
import {loadTranscript,loadOlderTranscript,putTranscript,refreshTranscript,prefetchTranscript,forgetPrefetchPauses} from '../src/missionCache';
import {applyStreamEvent} from '../src/transcriptModel';
import {cacheReset} from '../src/pageCache';
const row=(sequence:number,event_type:string,content:string,extra:Partial<StoredEvent>={}):StoredEvent=>({id:sequence,sequence,event_type,content,timestamp:'',...extra});
beforeEach(()=>{cacheReset();vi.clearAllMocks();});
it('loads a bounded tail, recovers older tool calls and preserves them on refresh',async()=>{
 vi.mocked(getMissionEventPage).mockResolvedValueOnce({events:[row(10,'user_message','Recent'),row(11,'assistant_message','Answer')],nextCursor:10,pageMax:11,hasMore:true});
 const tail=await loadTranscript('history');expect(tail.hasOlder).toBe(true);
 expect(getMissionEventPage).toHaveBeenCalledWith('history',{});
 vi.mocked(getMissionEventPage).mockResolvedValueOnce({events:[row(1,'user_message','Earlier')],nextCursor:1,pageMax:1,hasMore:false});
 const older=await loadOlderTranscript('history');expect(older.hasOlder).toBe(false);
 expect(older.items.some(i=>i.kind==='user'&&i.text==='Earlier')).toBe(true);
 putTranscript('history',older);
 vi.mocked(getMissionEventPage).mockResolvedValueOnce({events:[row(12,'assistant_message','Updated')],nextCursor:12,pageMax:12,hasMore:false});
 const refreshed=await refreshTranscript('history');expect(refreshed.hasOlder).toBe(false);
 expect(refreshed.items.some(i=>i.kind==='user'&&i.text==='Earlier')).toBe(true);
 expect(refreshed.items.some(i=>i.kind==='text'&&i.text==='Updated')).toBe(true);
});
it('can replay live events after an older page without mutating reducer state',async()=>{
 vi.mocked(getMissionEventPage).mockResolvedValueOnce({events:[row(10,'user_message','Current')],nextCursor:10,pageMax:10,hasMore:true});
 const tail=await loadTranscript('live');
 vi.mocked(getMissionEventPage).mockResolvedValueOnce({events:[row(1,'user_message','Earlier')],nextCursor:1,pageMax:1,hasMore:false});
 const older=await loadOlderTranscript('live');
 const live={type:'text_delta',eventId:'live',data:{content:'Streaming'}};
 const first=applyStreamEvent(older.items,live);
 const duplicate=applyStreamEvent(first,live);
 expect(duplicate.filter(i=>i.kind==='text').map(i=>i.kind==='text'?i.text:'')).toEqual(['Streaming']);
 expect(older.items.some(i=>i.kind==='text')).toBe(false);
});
it('empty older pages terminate pagination without losing existing content',async()=>{
 vi.mocked(getMissionEventPage).mockResolvedValueOnce({events:[row(8,'user_message','Only retained history')],nextCursor:8,pageMax:8,hasMore:true});
 const tail=await loadTranscript('empty');
 vi.mocked(getMissionEventPage).mockResolvedValueOnce({events:[],hasMore:false});
 const older=await loadOlderTranscript('empty');expect(older.hasOlder).toBe(false);expect(older.items).toEqual(tail.items);
});

it('bounds speculative reads while an opened conversation loads immediately',async()=>{
 forgetPrefetchPauses();
 const pending=new Map<string,(value:any)=>void>();
 vi.mocked(getMissionEventPage).mockImplementation(id=>new Promise(done=>pending.set(id,done)));
 for(const id of ['prefetch-a','prefetch-b','prefetch-c','prefetch-d','prefetch-e'])prefetchTranscript(id);
 await vi.waitFor(()=>expect(pending.size).toBe(4));
 const opened=loadTranscript('opened');
 await vi.waitFor(()=>expect(pending.has('opened')).toBe(true));
 const empty={events:[],hasMore:false,pageMax:0};
 pending.get('opened')!(empty);await opened;
 pending.get('prefetch-a')!(empty);
 await vi.waitFor(()=>expect(pending.has('prefetch-e')).toBe(true));
 for(const id of ['prefetch-b','prefetch-c','prefetch-d','prefetch-e'])pending.get(id)!(empty);
 await vi.waitFor(()=>expect(getMissionEventPage).toHaveBeenCalledTimes(6));
});
