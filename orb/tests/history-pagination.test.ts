import {beforeEach, expect, it, vi} from 'vitest';
vi.mock('../src/api',()=>({connectionVersion:()=>0,listQueuedMessages:vi.fn(async()=>[])}));
vi.mock('../src/stream',async original=>({...await original<typeof import('../src/stream')>(),getMissionEvents:vi.fn()}));
import {getMissionEvents, type StoredEvent} from '../src/stream';
import {loadTranscript,olderTranscript,putTranscript,refreshTranscript} from '../src/missionCache';
import {applyStreamEvent} from '../src/transcriptModel';
import {cacheReset} from '../src/pageCache';
const row=(sequence:number,event_type:string,content:string,extra:Partial<StoredEvent>={}):StoredEvent=>({id:sequence,sequence,event_type,content,timestamp:'',...extra});
beforeEach(()=>{cacheReset();vi.clearAllMocks();});
it('loads a bounded tail, recovers older tool calls and preserves them on refresh',async()=>{
 vi.mocked(getMissionEvents).mockResolvedValueOnce([row(10,'user_message','Recent'),row(11,'assistant_message','Answer')]);
 const tail=await loadTranscript('history');expect(tail.hasMore).toBe(true);
 expect(getMissionEvents).toHaveBeenCalledWith('history',{limit:1000});
 vi.mocked(getMissionEvents).mockResolvedValueOnce([row(1,'user_message','Earlier')]);
 const older=await olderTranscript('history',tail);expect(older.hasMore).toBe(false);
 expect(older.items.some(i=>i.kind==='user'&&i.text==='Earlier')).toBe(true);
 putTranscript('history',older);
 vi.mocked(getMissionEvents).mockResolvedValueOnce([row(10,'user_message','Recent'),row(11,'assistant_message','Updated')]);
 const refreshed=await refreshTranscript('history');expect(refreshed.hasMore).toBe(false);
 expect(refreshed.items.some(i=>i.kind==='user'&&i.text==='Earlier')).toBe(true);
 expect(refreshed.items.some(i=>i.kind==='text'&&i.text==='Updated')).toBe(true);
});
it('can replay live events after an older page without mutating reducer state',async()=>{
 vi.mocked(getMissionEvents).mockResolvedValueOnce([row(10,'user_message','Current')]);
 const tail=await loadTranscript('live');
 vi.mocked(getMissionEvents).mockResolvedValueOnce([row(1,'user_message','Earlier')]);
 const older=await olderTranscript('live',tail);
 const live={type:'text_delta',eventId:'live',data:{content:'Streaming'}};
 const first=applyStreamEvent(older.items,live);
 const duplicate=applyStreamEvent(first,live);
 expect(duplicate.filter(i=>i.kind==='text').map(i=>i.kind==='text'?i.text:'')).toEqual(['Streaming']);
 expect(older.items.some(i=>i.kind==='text')).toBe(false);
});
it('empty older pages terminate pagination without losing existing content',async()=>{
 vi.mocked(getMissionEvents).mockResolvedValueOnce([row(8,'user_message','Only retained history')]);
 const tail=await loadTranscript('empty');
 vi.mocked(getMissionEvents).mockResolvedValueOnce([]);
 const older=await olderTranscript('empty',tail);expect(older.hasMore).toBe(false);expect(older.items).toEqual(tail.items);
});
