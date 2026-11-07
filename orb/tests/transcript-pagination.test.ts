import {beforeEach,expect,it,vi} from 'vitest';
const mocks=vi.hoisted(()=>({version:0,page:vi.fn(),queue:vi.fn()}));
vi.mock('../src/api',()=>({connectionVersion:()=>mocks.version,listQueuedMessages:mocks.queue}));
vi.mock('../src/stream',async original=>({...await original<typeof import('../src/stream')>(),getMissionEventPreview:vi.fn(async()=>null),getMissionEventPage:mocks.page}));
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
it('still hydrates the conversational spine when a tool-heavy tail only has canonical narration or queued user messages',async()=>{
 mocks.page
  .mockResolvedValueOnce({events:[
   {id:9200,event_id:'ac-9200',sequence:9200,event_type:'assistant_message_canonical',content:'Mid-turn status note',timestamp:'2026-11-03T01:10:00Z',metadata:{bubble_id:'b-1',revision:1}},
   {id:9250,event_id:'uq-1',sequence:9250,event_type:'user_message',content:'Queued follow-up',timestamp:'2026-11-03T01:11:00Z',metadata:{queued:true}},
  ],nextCursor:9200,pageMax:9300,hasMore:true})
  .mockResolvedValueOnce({events:[
   {id:8000,event_id:'u-active',sequence:8000,event_type:'user_message',content:'Start long turn',timestamp:'2026-11-03T01:00:00Z'},
  ],nextCursor:8000,pageMax:8000,hasMore:false});
 const initial=await loadTranscript('canonical-tail');
 expect(mocks.page.mock.calls).toEqual([['canonical-tail',{}],['canonical-tail',{before:9200,view:'transcript'}]]);
 const delivered=initial.items.find(i=>i.kind==='user'&&!i.queued);
 expect(delivered).toMatchObject({kind:'user',text:'Start long turn',at:'2026-11-03T01:00:00Z'});
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


import {getMissionEventPreview} from '../src/stream';
import {peekReadyTranscript,peekTranscript} from '../src/missionCache';
it('publishes the final answer before activity and queue settle, without advancing raw cursors',async()=>{
 vi.mocked(getMissionEventPreview).mockResolvedValueOnce({events:[row(6497,'Final response')],nextCursor:6497,pageMax:6497,hasMore:true});
 let finishActivity!:(value:any)=>void,finishQueue!:(value:any)=>void;
 mocks.page.mockImplementationOnce(()=>new Promise(resolve=>finishActivity=resolve));
 mocks.queue.mockImplementationOnce(()=>new Promise(resolve=>finishQueue=resolve));
 const loading=loadTranscript('priority');
 await vi.waitFor(()=>expect(peekTranscript('priority')?.detailsPending).toBe(true));
 expect(peekTranscript('priority')?.items).toMatchObject([{kind:'text',text:'Final response'}]);
 expect(peekTranscript('priority')?.cursor).toBeUndefined();
 expect(peekReadyTranscript('priority')).toBeUndefined();
 expect(loadTranscript('priority')).toBe(loading);
 expect(refreshTranscript('priority')).toBe(loading);
 finishActivity({events:[row(6497,'Final response')],nextCursor:6298,pageMax:6500,hasMore:true});
 finishQueue([]);
 const hydrated=await loading;
 expect(hydrated.detailsPending).toBeUndefined();
 expect(hydrated.cursor).toBe(6500);
 expect(hydrated.items.filter(i=>i.kind==='text'&&i.text==='Final response')).toHaveLength(1);
});
it('keeps a failed activity hydration readable but retries it on reopen',async()=>{
 vi.mocked(getMissionEventPreview).mockResolvedValue({events:[row(9,'Saved response')],nextCursor:9,pageMax:9,hasMore:false});
 mocks.page.mockRejectedValueOnce(new Error('activity unavailable'));
 await expect(loadTranscript('retry-preview')).rejects.toThrow('activity unavailable');
 expect(peekTranscript('retry-preview')?.detailsPending).toBe(true);
 mocks.page.mockResolvedValueOnce({events:[row(9,'Saved response')],nextCursor:9,pageMax:9,hasMore:false});
 const reopened=await loadTranscript('retry-preview');
 expect(reopened.detailsPending).toBeUndefined();
 expect(reopened.items).toMatchObject([{text:'Saved response'}]);
 vi.mocked(getMissionEventPreview).mockResolvedValue(null as any);
});

it('preserves cached conversational spine and hydrates intervening turns across >400-event forward gaps even when tail ends with assistant_message (mission c2dcb8ab)',async()=>{
 const toolCall=(seq:number,callId:string,name='run_command',content='{"CommandLine":"ls"}')=>({id:seq,event_id:`ev-${seq}`,sequence:seq,event_type:'tool_call',tool_call_id:callId,tool_name:name,content,timestamp:''});
 const toolResult=(seq:number,callId:string)=>({id:seq,event_id:`ev-${seq}`,sequence:seq,event_type:'tool_result',tool_call_id:callId,tool_name:'run_command',content:'ok',timestamp:''});
 // Stage 1: mission cached up to seq=1910 with prior turns
 mocks.page.mockResolvedValueOnce({
  events:[
   {id:1,event_id:'u-1',sequence:1,event_type:'user_message',content:'Initial goal',timestamp:''},
   {id:100,event_id:'a-1',sequence:100,event_type:'assistant_message',content:'Initial answer',timestamp:''},
   {id:1910,event_id:'u-34',sequence:1910,event_type:'user_message',content:'Run turbo-lean receipt verification',timestamp:''},
  ],
  nextCursor:1,pageMax:1910,hasMore:false,
 });
 const stage1 = await loadTranscript('c2dcb8ab');
 expect(stage1.items.filter(i=>i.kind==='user').map(i=>i.kind==='user'?i.text:'')).toEqual(['Initial goal','Run turbo-lean receipt verification']);

 // Stage 2+3: >2,200 unfocused tool events stream (seq 1911..4249), ending with todowrite + final assistant_message (seq=4248)
 mocks.page
  .mockResolvedValueOnce({events:[toolCall(1911,'c-1911'),toolResult(1912,'c-1911')],nextCursor:2110,pageMax:2110,hasMore:true})
  .mockResolvedValueOnce({events:[toolCall(2111,'c-2111'),toolResult(2112,'c-2111')],nextCursor:2310,pageMax:2310,hasMore:true})
  .mockResolvedValueOnce({
   events:[
    toolCall(4051,'c-4051'),
    toolResult(4052,'c-4051'),
    toolCall(4240,'todo-1','todowrite',JSON.stringify({todos:[{content:'Fix turbo_verify.py',status:'completed'}]})),
    toolResult(4241,'todo-1'),
    {id:4248,event_id:'a-final',sequence:4248,event_type:'assistant_message',content:'Replaced PR #32 with passing turbo benchmark.',timestamp:''},
   ],
   nextCursor:4051,pageMax:4249,hasMore:true,
  })
  .mockResolvedValueOnce({
   events:[
    {id:1,event_id:'u-1',sequence:1,event_type:'user_message',content:'Initial goal',timestamp:''},
    {id:100,event_id:'a-1',sequence:100,event_type:'assistant_message',content:'Initial answer',timestamp:''},
    {id:1910,event_id:'u-34',sequence:1910,event_type:'user_message',content:'Run turbo-lean receipt verification',timestamp:''},
    {id:3200,event_id:'a-mid',sequence:3200,event_type:'assistant_message',content:'Checking CI logs before final verification...',timestamp:''},
   ],
   nextCursor:1,pageMax:3200,hasMore:false,
  });

 const refreshed = await refreshTranscript('c2dcb8ab');
 expect(mocks.page.mock.calls.slice(1)).toEqual([
  ['c2dcb8ab',{since:1910}],
  ['c2dcb8ab',{since:2110}],
  ['c2dcb8ab',{}],
  ['c2dcb8ab',{before:4051,view:'transcript'}],
 ]);
 // Prior turns stay visible above the work fold AND intermediate narration at seq=3200 is suppressed by tailAnswered=true because seq=4248 answered the turn!
 expect(refreshed.items.filter(i=>i.kind==='user').map(i=>i.kind==='user'?i.text:'')).toEqual([
  'Initial goal',
  'Run turbo-lean receipt verification',
 ]);
 expect(refreshed.items.filter(i=>i.kind==='text').map(i=>i.kind==='text'?i.text:'')).toEqual([
  'Initial answer',
  'Replaced PR #32 with passing turbo benchmark.',
 ]);
 expect(refreshed.spineComplete).toBe(true);
});

it('hydrates spine on cold tail load when 200-event tool tail ends with assistant_message but lacks turn user_message',async()=>{
 const toolCall=(seq:number,callId:string)=>({id:seq,event_id:`ev-${seq}`,sequence:seq,event_type:'tool_call',tool_call_id:callId,tool_name:'run_command',content:'{"CommandLine":"ls"}',timestamp:''});
 const toolResult=(seq:number,callId:string)=>({id:seq,event_id:`ev-${seq}`,sequence:seq,event_type:'tool_result',tool_call_id:callId,tool_name:'run_command',content:'ok',timestamp:''});
 mocks.page
  .mockResolvedValueOnce({
   events:[
    toolCall(4051,'c-4051'),
    toolResult(4052,'c-4051'),
    {id:4248,event_id:'a-4248',sequence:4248,event_type:'assistant_message',content:'Final agent report',timestamp:''},
   ],
   nextCursor:4051,pageMax:4249,hasMore:true,
  })
  .mockResolvedValueOnce({
   events:[
    {id:1910,event_id:'u-1910',sequence:1910,event_type:'user_message',content:'Audit PR #32',timestamp:''},
   ],
   nextCursor:1910,pageMax:1910,hasMore:false,
  });
 const snap = await loadTranscript('cold-tool-plus-reply');
 expect(mocks.page.mock.calls).toEqual([
  ['cold-tool-plus-reply',{}],
  ['cold-tool-plus-reply',{before:4051,view:'transcript'}],
 ]);
 expect(snap.items.filter(i=>i.kind==='user').map(i=>i.kind==='user'?i.text:'')).toEqual(['Audit PR #32']);
 expect(snap.items.filter(i=>i.kind==='text').map(i=>i.kind==='text'?i.text:'')).toEqual(['Final agent report']);
});

it('recovers conversational spine in one loadOlderTranscript step if initial spine hydration failed and raw page is tool-only',async()=>{
 const toolCall=(seq:number,callId:string)=>({id:seq,event_id:`ev-${seq}`,sequence:seq,event_type:'tool_call',tool_call_id:callId,tool_name:'run_command',content:'{"CommandLine":"ls"}',timestamp:''});
 const toolResult=(seq:number,callId:string)=>({id:seq,event_id:`ev-${seq}`,sequence:seq,event_type:'tool_result',tool_call_id:callId,tool_name:'run_command',content:'ok',timestamp:''});
 mocks.page
  .mockResolvedValueOnce({events:[toolCall(4051,'c-4051'),toolResult(4052,'c-4051')],nextCursor:4051,pageMax:4247,hasMore:true})
  .mockRejectedValueOnce(new Error('transient spine timeout'));
 const initial = await loadTranscript('recover-spine');
 expect(initial.spineComplete).toBe(false);

 mocks.page
  .mockResolvedValueOnce({events:[toolCall(3851,'c-3851'),toolResult(3852,'c-3851')],nextCursor:3851,pageMax:4050,hasMore:true})
  .mockResolvedValueOnce({
   events:[{id:1910,event_id:'u-1910',sequence:1910,event_type:'user_message',content:'Original prompt',timestamp:''}],
   nextCursor:1910,pageMax:1910,hasMore:false,
  });
 const older = await loadOlderTranscript('recover-spine');
 expect(mocks.page.mock.calls.slice(2)).toEqual([
  ['recover-spine',{before:4051}],
  ['recover-spine',{before:3851,view:'transcript'}],
 ]);
 expect(older.spineComplete).toBe(true);
 expect(older.items.some(i=>i.kind==='user'&&i.text==='Original prompt')).toBe(true);
});
