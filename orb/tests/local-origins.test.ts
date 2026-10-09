import {afterEach,expect,it,vi} from 'vitest';
import {getMission,listMissions,listProjectMissions,archiveMission,reopenMission,renameMission,setConnection,clearConnection} from '../src/api';
afterEach(()=>{delete (window as any).__TAURI_INTERNALS__;clearConnection();vi.unstubAllGlobals();});
it('shows a locally journaled mission and its text while Core is offline',async()=>{
 setConnection('http://offline.test','token');
 const mission={id:'local-id',title:'Offline task',status:'active',created_at:'now',updated_at:'now',history:[{role:'user',content:'Do work'},{role:'assistant',content:'Working'}],local_sync_pending:true};
 const invoke=vi.fn(async()=>[mission]);(window as any).__TAURI_INTERNALS__={invoke};
 const fetcher=vi.fn(async()=>{throw new TypeError('offline');});vi.stubGlobal('fetch',fetcher);
 expect(await getMission(mission.id)).toEqual(mission);expect(fetcher).toHaveBeenCalledTimes(1);
 expect(await listMissions()).toEqual([mission]);
 expect(invoke).toHaveBeenCalledWith('local_origin_list',expect.objectContaining({connection:{api_url:'http://offline.test',token:'token'}}));
});
it('does not replace a newer Core conversation with a completed local snapshot',async()=>{
 setConnection('http://online.test','token');
 const old={id:'id',status:'awaiting_user',history:[],local_sync_pending:false};(window as any).__TAURI_INTERNALS__={invoke:vi.fn(async()=>[old])};
 vi.stubGlobal('fetch',vi.fn(async()=>new Response(JSON.stringify({...old,status:'completed',title:'Updated on Core'}))));
 expect((await getMission('id')).title).toBe('Updated on Core');
});

/** The desktop journal as Rust keeps it: newest observation wins, unsynchronized work is never overruled. */
function journal(rows:any[]){
 const confirmed=new Map<string,{status?:string;title?:string;deleted?:boolean;observed_at:number}>();
 const pending=(row:any)=>!!row.local_sync_pending||row.status==='active';
 const invoke=vi.fn(async(command:string,args:any)=>{
  if(command==='local_origin_list')return rows.flatMap(row=>{const c=confirmed.get(row.id);if(!pending(row)&&c?.deleted)return [];const shown=c&&!pending(row)?{...row,status:c.status??row.status,title:c.title??row.title}:row;return [{...shown,local_run_active:row.status==='active'}];});
  if(command==='local_origin_confirm'){for(const c of args.confirmations){const row=rows.find(r=>r.id===c.id),old=confirmed.get(c.id);if(!row||pending(row)||(old&&c.observed_at<=old.observed_at))continue;confirmed.set(c.id,{...old,...c});}return;}
  throw new Error(`unknown command ${command}`);
 });
 (window as any).__TAURI_INTERNALS__={invoke};
 return {invoke,confirmed};
}
const done={id:'done',title:'Finished locally',status:'awaiting_user',project:'test',history:[],local_sync_pending:false};
const unsynced={id:'unsynced',title:'Not on Core yet',status:'awaiting_user',project:'test',history:[],local_sync_pending:true};
const core=(list:any[])=>vi.fn(async()=>new Response(JSON.stringify(list)));
const offline=()=>vi.fn(async()=>{throw new TypeError('offline');});

it('restarts offline with the archive, restore and title Core confirmed',async()=>{
 setConnection('http://core.test','token');journal([done,unsynced]);
 vi.stubGlobal('fetch',core([{...done,status:'acknowledged',title:'Renamed on Core'}]));
 expect((await listProjectMissions('test')).map(m=>[m.id,m.status])).toEqual([['unsynced','awaiting_user'],['done','acknowledged']]);
 // Restart without Core: the journal is all Orb has.
 vi.stubGlobal('fetch',offline());
 expect(await listProjectMissions('test')).toMatchObject([{id:'done',status:'acknowledged',title:'Renamed on Core'},{id:'unsynced',status:'awaiting_user',title:'Not on Core yet'}]);
 expect((await getMission('done')).status).toBe('acknowledged');
});
it('recovers after a failed first request once Core answers again',async()=>{
 setConnection('http://core.test','token');const {confirmed}=journal([done]);
 vi.stubGlobal('fetch',offline());
 expect(await listProjectMissions('test')).toMatchObject([{id:'done',status:'awaiting_user'}]);
 expect(confirmed.size).toBe(0);
 vi.stubGlobal('fetch',core([{...done,status:'acknowledged'}]));
 expect(await listProjectMissions('test')).toMatchObject([{id:'done',status:'acknowledged'}]);
 vi.stubGlobal('fetch',offline());
 expect(await listMissions()).toMatchObject([{id:'done',status:'acknowledged'}]);
});
it('remembers archive, restore and rename as soon as Core accepts them',async()=>{
 setConnection('http://core.test','token');journal([done]);
 const state={...done};
 vi.stubGlobal('fetch',vi.fn(async(input:any,init?:any)=>{
  const url=String(input),body=init?.body?JSON.parse(String(init.body)):{};
  if(url.endsWith('/status'))state.status=body.status;
  if(url.endsWith('/title'))state.title=body.title;
  return new Response(JSON.stringify(init?.method==='POST'?{}:state));
 }));
 await archiveMission('done');await renameMission('done','Kept name');
 vi.stubGlobal('fetch',offline());
 expect(await listProjectMissions('test')).toMatchObject([{status:'acknowledged',title:'Kept name'}]);
 vi.unstubAllGlobals();
 vi.stubGlobal('fetch',vi.fn(async(input:any,init?:any)=>{if(String(input).endsWith('/status'))state.status=JSON.parse(String(init.body)).status;return new Response(JSON.stringify(init?.method==='POST'?{}:state));}));
 await reopenMission('done');
 vi.stubGlobal('fetch',offline());
 expect(await listProjectMissions('test')).toMatchObject([{status:'paused',title:'Kept name'}]);
});
it('keeps the archive when a list requested before it answers afterwards',async()=>{
 setConnection('http://core.test','token');const {confirmed}=journal([done]);
 let releaseList!:(response:Response)=>void;
 const clock=vi.spyOn(Date,'now');
 clock.mockReturnValue(1000);
 vi.stubGlobal('fetch',vi.fn((input:any,init?:any)=>{
  const url=String(input);
  if(url.includes('project=test'))return new Promise<Response>(resolve=>{releaseList=resolve;});
  return Promise.resolve(new Response(JSON.stringify(init?.method==='POST'?{}:done)));
 }));
 const stale=listProjectMissions('test');
 await vi.waitFor(()=>expect(releaseList).toBeTypeOf('function'));
 clock.mockReturnValue(2000);
 await archiveMission('done');
 // Core answers the earlier request with the state it had before the archive.
 releaseList(new Response(JSON.stringify([{...done,title:'Stale title'}])));
 await stale;
 expect(confirmed.get('done')).toMatchObject({status:'acknowledged'});expect(confirmed.get('done')!.observed_at).toBeGreaterThanOrEqual(2000);
 clock.mockRestore();
 vi.stubGlobal('fetch',offline());
 expect(await listProjectMissions('test')).toMatchObject([{status:'acknowledged',title:'Finished locally'}]);
});
it('works with a desktop build that cannot remember confirmations',async()=>{
 setConnection('http://core.test','token');
 (window as any).__TAURI_INTERNALS__={invoke:vi.fn(async(command:string)=>{if(command==='local_origin_list')return [done];throw new Error('unknown command local_origin_confirm');})};
 vi.stubGlobal('fetch',core([{...done,status:'acknowledged'}]));
 expect(await listProjectMissions('test')).toMatchObject([{id:'done',status:'acknowledged'}]);
});
it('does not mistake a running status confirmed by Core for local work',async()=>{
 setConnection('http://core.test','token');const {confirmed}=journal([done]);
 // Core resumed the mission elsewhere, then it was interrupted.
 vi.stubGlobal('fetch',core([{...done,status:'active'}]));
 expect(await listProjectMissions('test')).toMatchObject([{id:'done',status:'active'}]);
 expect(confirmed.get('done')?.status).toBe('active');
 vi.stubGlobal('fetch',core([{...done,status:'interrupted',title:'From Core'}]));
 const rows=await listProjectMissions('test');
 expect(rows).toHaveLength(1);
 expect(rows[0]).toMatchObject({status:'interrupted',title:'From Core'});
 expect(rows[0].local_run_active).toBeUndefined();
 expect(confirmed.get('done')?.status).toBe('interrupted');
 vi.stubGlobal('fetch',vi.fn(async()=>new Response(JSON.stringify({...done,status:'interrupted'}))));
 expect((await getMission('done')).status).toBe('interrupted');
});
it('learns about an archive the default list leaves out, and keeps an emptied title',async()=>{
 setConnection('http://core.test','token');journal([done,unsynced]);
 const asked:string[]=[];
 vi.stubGlobal('fetch',vi.fn(async(input:any)=>{
  const url=String(input);asked.push(url);
  // The default list shows attention rows only: the archived mission is absent.
  if(new URL(url).pathname === '/api/control/missions')return new Response('[]');
  if(url.endsWith('/missions/done'))return new Response(JSON.stringify({...done,status:'acknowledged',title:''}));
  return new Response('Not found',{status:404});
 }));
 await listMissions();
 expect(asked.some(url=>url.endsWith('/missions/unsynced'))).toBe(false);
 vi.stubGlobal('fetch',offline());
 expect((await listMissions()).find(m=>m.id==='done')).toMatchObject({status:'acknowledged',title:''});
});
it('retires a synchronized local mission once Core confirms 404 or explicit deletion',async()=>{
 setConnection('http://core.test','token');const {confirmed}=journal([done,unsynced]);
 const {forgetUnlistedReads}=await import('../src/localOrigins');
 forgetUnlistedReads();
 vi.stubGlobal('fetch',vi.fn(async(input:any)=>{
  const url=String(input);
  if(new URL(url).pathname === '/api/control/missions')return new Response('[]');
  return new Response('Not found',{status:404});
 }));
 await listMissions();
 expect(confirmed.get('done')?.deleted).toBe(true);
 expect(confirmed.get('unsynced')).toBeUndefined();
 vi.stubGlobal('fetch',offline());
 expect((await listMissions()).map(m=>m.id)).toEqual(['unsynced']);
});

it('shares concurrent native scans and reads fresh rows after completion',async()=>{
 setConnection('http://core.test','token');
 let resolve!:(rows:any[])=>void;
 const invoke=vi.fn(()=>new Promise<any[]>(done=>resolve=done));
 (window as any).__TAURI_INTERNALS__={invoke};
 const {localOrigins}=await import('../src/localOrigins');
 const first=localOrigins('one'),second=localOrigins('two');
 expect(invoke).toHaveBeenCalledTimes(1);
 resolve([{id:'one'},{id:'two'}]);
 expect(await first).toEqual([{id:'one'}]);expect(await second).toEqual([{id:'two'}]);
 const next=localOrigins();expect(invoke).toHaveBeenCalledTimes(2);resolve([]);await next;
});

it('keeps local output but reads current Antigravity effort from Core while running',async()=>{
 setConnection('http://core.test','token');
 const local={...done,status:'active',backend:'antigravity',model_override:'agy-demo',model_effort:'low',local_sync_pending:true,history:[{role:'assistant',content:'Unsynced output'}]};
 journal([local]);
 let effort:string|null='high';
 vi.stubGlobal('fetch',vi.fn(async(input:any)=>new Response(JSON.stringify(String(input).includes('?')?[{...done,backend:'antigravity',model_override:'agy-demo',model_effort:effort}]:{...done,backend:'antigravity',model_override:'agy-demo',model_effort:effort}))));
 expect(await getMission('done')).toMatchObject({...local,model_effort:'high'});
 expect(await listMissions()).toMatchObject([{...local,model_effort:'high'}]);
 expect(await listProjectMissions('test')).toMatchObject([{...local,model_effort:'high'}]);
 effort=null;
 expect(await getMission('done')).toMatchObject({...local,model_effort:null});
});
