import {beforeEach,expect,it,vi} from 'vitest';
const mocks=vi.hoisted(()=>({version:0,page:vi.fn(),queue:vi.fn()}));
vi.mock('../src/api',()=>({connectionVersion:()=>mocks.version,listQueuedMessages:mocks.queue}));
vi.mock('../src/stream',async original=>({...await original<typeof import('../src/stream')>(),getMissionEventPage:mocks.page}));
import {loadTranscript,refreshTranscript,loadOlderTranscript} from '../src/missionCache';
import {cacheReset} from '../src/pageCache';
beforeEach(()=>{cacheReset();mocks.version=0;mocks.page.mockReset();mocks.queue.mockReset().mockResolvedValue([]);});
const row=(id:number,text:string)=>({id,event_id:`event-${id}`,sequence:id,event_type:'assistant_message',content:text,timestamp:''});
it('keeps empty snapshots valid and avoids repeated history fetches',async()=>{
 mocks.page.mockResolvedValue({events:[],hasMore:false});
 await Promise.all([loadTranscript('m'),loadTranscript('m')]);await loadTranscript('m');expect(mocks.page).toHaveBeenCalledTimes(1);
});
it('uses consumed raw cursors across condensed forward pages, not visible row sequences',async()=>{
 mocks.page.mockResolvedValueOnce({events:[row(5,'first')],nextCursor:1,pageMax:1000,hasMore:true})
 .mockResolvedValueOnce({events:[row(1500,'second')],nextCursor:2000,pageMax:2000,hasMore:true})
 .mockResolvedValueOnce({events:[row(2200,'third')],nextCursor:3000,pageMax:3000,hasMore:false});
 await loadTranscript('m');const result=await refreshTranscript('m');
 expect(mocks.page.mock.calls).toEqual([['m',{}],['m',{since:1000}],['m',{since:2000}]]);
 expect(result.cursor).toBe(3000);expect(result.items.filter(i=>i.kind==='text').map(i=>i.text)).toEqual(['first','second','third']);
});
it('prepends history without changing existing message keys or dropping queued evidence',async()=>{
 mocks.queue.mockResolvedValue([{id:'queued',content:'next',mission_id:'m'}]);
 mocks.page.mockResolvedValueOnce({events:[row(2000,'recent')],nextCursor:1001,pageMax:2000,hasMore:true})
 .mockResolvedValueOnce({events:[row(1000,'older')],nextCursor:1,pageMax:1000,hasMore:false});
 const initial=await loadTranscript('m'),key=initial.items.find(i=>i.kind==='text')!.key;
 const older=await loadOlderTranscript('m');
 expect(older.items.find(i=>i.kind==='text'&&i.text==='recent')!.key).toBe(key);
 expect(older.items.some(i=>i.kind==='user'&&i.messageId==='queued')).toBe(true);
 expect(mocks.page).toHaveBeenLastCalledWith('m',{before:1001});
});
it('rejects a response from a replaced connection',async()=>{
 let finish!:(page:unknown)=>void;mocks.page.mockImplementation(()=>new Promise(resolve=>finish=resolve));
 const loading=loadTranscript('m');await vi.waitFor(()=>expect(mocks.page).toHaveBeenCalled());
 mocks.version++;finish({events:[],hasMore:false});await expect(loading).rejects.toThrow('Connection changed');
});
it('serializes backward pagination and reconnect recovery without conflating them',async()=>{
 mocks.page.mockResolvedValueOnce({events:[row(2000,'recent')],nextCursor:1001,pageMax:2000,hasMore:true});
 await loadTranscript('m');let finish!:(value:unknown)=>void;
 mocks.page.mockImplementationOnce(()=>new Promise(resolve=>finish=resolve)).mockResolvedValueOnce({events:[row(2001,'new')],nextCursor:2001,pageMax:2001,hasMore:false});
 const older=loadOlderTranscript('m'),refresh=refreshTranscript('m');
 await vi.waitFor(()=>expect(mocks.page).toHaveBeenCalledTimes(2));
 finish({events:[row(1000,'old')],nextCursor:1,pageMax:1000,hasMore:false});
 await older;const result=await refresh;
 expect(mocks.page).toHaveBeenLastCalledWith('m',{since:2000});
 expect(result.items.filter(i=>i.kind==='text').map(i=>i.text)).toEqual(['old','recent','new']);
});
it('reconstructs an invalid cursor rather than retaining a restored database tail',async()=>{
 mocks.page.mockResolvedValueOnce({events:[row(5000,'old database')],nextCursor:4001,pageMax:5000,hasMore:true});await loadTranscript('m');
 mocks.page.mockResolvedValueOnce({events:[],hasMore:false,reset:true}).mockResolvedValueOnce({events:[row(2,'restored')],nextCursor:1,pageMax:2,hasMore:false});
 const result=await refreshTranscript('m');expect(result.items.filter(i=>i.kind==='text').map(i=>i.text)).toEqual(['restored']);expect(result.cursor).toBe(2);
});
it('hydrates the conversational spine when a tool-heavy tail page has no user or assistant messages',async()=>{
 const toolCall=(seq:number,callId:string)=>({id:seq,event_id:`ev-${seq}`,sequence:seq,event_type:'tool_call',tool_call_id:callId,tool_name:'run_command',content:'{"CommandLine":"ls"}',timestamp:''});
 const toolResult=(seq:number,callId:string)=>({id:seq,event_id:`ev-${seq}`,sequence:seq,event_type:'tool_result',tool_call_id:callId,tool_name:'run_command',content:'ok',timestamp:''});
 // Simulate mission 3d921fb4: tail page (seq 9114..9313) is pure tool calls/results with hasMore=true
 mocks.page
  .mockResolvedValueOnce({events:[toolCall(9114,'c-9114'),toolResult(9115,'c-9114')],nextCursor:9114,pageMax:9313,hasMore:true})
  .mockResolvedValueOnce({events:[
   {id:1,event_id:'u-1',sequence:1,event_type:'user_message',content:'Initial prompt',timestamp:''},
   {id:100,event_id:'a-1',sequence:100,event_type:'assistant_message',content:'First reply',timestamp:''},
   {id:4241,event_id:'u-19',sequence:4241,event_type:'user_message',content:'Latest user follow-up',timestamp:''},
   {id:5913,event_id:'ac-112',sequence:5913,event_type:'assistant_message_canonical',content:'Latest canonical update before 3400 tool calls',timestamp:'',metadata:{bubble_id:'antigravity:conv:112',revision:1}},
  ],nextCursor:1,pageMax:5913,hasMore:false});
 const initial=await loadTranscript('yukon');
 expect(mocks.page.mock.calls).toEqual([['yukon',{}],['yukon',{before:9114,view:'transcript'}]]);
 expect(initial.before).toBe(9114);
 expect(initial.cursor).toBe(9313);
 expect(initial.hasOlder).toBe(true);
 expect(initial.items.filter(i=>i.kind==='user').map(i=>i.kind==='user'?i.text:'')).toEqual(['Initial prompt','Latest user follow-up']);
 expect(initial.items.filter(i=>i.kind==='text').map(i=>i.kind==='text'?i.text:'')).toEqual(['First reply','Latest canonical update before 3400 tool calls']);
 expect(initial.items.at(-1)).toMatchObject({kind:'tool',callId:'c-9114',done:true});

 // Paging older events merges intermediate tool calls and deduplicates the spine messages
 mocks.page.mockResolvedValueOnce({events:[
  {id:5913,event_id:'ac-112',sequence:5913,event_type:'assistant_message_canonical',content:'Latest canonical update before 3400 tool calls',timestamp:'',metadata:{bubble_id:'antigravity:conv:112',revision:1}},
  toolCall(6000,'c-6000'),
  toolResult(6001,'c-6000'),
 ],nextCursor:5913,pageMax:9113,hasMore:true});
 const older=await loadOlderTranscript('yukon');
 expect(older.items.filter(i=>i.kind==='text').map(i=>i.kind==='text'?i.text:'')).toEqual(['First reply','Latest canonical update before 3400 tool calls']);
 expect(older.items.filter(i=>i.kind==='tool').map(i=>i.kind==='tool'?i.callId:'')).toEqual(['c-6000','c-9114']);
});
it('joins an in-flight initial load when refreshTranscript is called before initial completes',async()=>{
 let finish!:(page:unknown)=>void;
 mocks.page.mockImplementation(()=>new Promise(resolve=>finish=resolve));
 const initial=loadTranscript('coalesce');
 const refresh=refreshTranscript('coalesce');
 expect(refresh).toBe(initial);
 await vi.waitFor(()=>expect(mocks.page).toHaveBeenCalledTimes(1));
 finish({events:[row(10,'loaded once')],nextCursor:10,pageMax:10,hasMore:false});
 const [a,b]=await Promise.all([initial,refresh]);
 expect(a).toEqual(b);
 expect(mocks.page).toHaveBeenCalledTimes(1);
});

