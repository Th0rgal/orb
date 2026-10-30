import { expect, it, vi, beforeEach } from 'vitest';
vi.mock('../src/api',()=>({ api:vi.fn(),getApiUrl:()=> 'https://core',getMission:vi.fn(),connectionVersion:()=>0 }));
import { api, getMission } from '../src/api';
import { moveMission, readCutMission } from '../src/missionMove';
const id='524754fe-3acc-42c1-ba7f-89ee2d296bcb';
beforeEach(()=>vi.clearAllMocks());
it('accepts only a mission cut from the same backend',()=>{
 expect(readCutMission('orb:cut-mission:'+JSON.stringify({id,backend:'https://core'}),'https://core')).toBe(id);
 expect(readCutMission('orb:cut-mission:'+JSON.stringify({id,backend:'https://other'}),'https://core')).toBeNull();
 expect(readCutMission('ordinary text','https://core')).toBeNull();
 expect(readCutMission('orb:cut-mission:{','https://core')).toBeNull();
});
it('preserves placement and other tags when moving to a folder',async()=>{
 vi.mocked(getMission).mockResolvedValue({id,tags:['placement:client','orb-folder:old','writer']} as any);
 await moveMission(id,'other-project','notes/review');
 const request=vi.mocked(api).mock.calls[0][1]!;
 expect(JSON.parse(request.body as string)).toEqual({project:'other-project',tags:['placement:client','writer','orb-folder:notes/review']});
});
it('removes folder classification when pasting at project root and propagates rejection',async()=>{
 vi.mocked(getMission).mockResolvedValue({id,tags:['orb-folder:old','keep']} as any);
 vi.mocked(api).mockRejectedValueOnce(new Error('busy'));
 await expect(moveMission(id,'project','')).rejects.toThrow('busy');
 expect(JSON.parse(vi.mocked(api).mock.calls[0][1]!.body as string)).toEqual({project:'project',tags:['keep']});
});

import { moveMissions, planMissionMoves } from '../src/missionMove';
import { pendingMoves, resetMoves } from '../src/moves';
import { runningWorkerIds } from '../src/deleteRunning';
const P='11111111-1111-1111-1111-111111111111', F='22222222-2222-2222-2222-222222222222', C='33333333-3333-3333-3333-333333333333', G='44444444-4444-4444-4444-444444444444';
const known=[{id:P,project:'verity'},{id:F,project:'verity'},{id:C,project:'verity',parent_mission_id:P},{id:G,project:'verity',parent_mission_id:C}];
it('plans every selected mission; inside a project the children follow their parent without writes',()=>{
 expect(planMissionMoves([P,F],'verity','Audits',known)).toEqual([{id:P,from:'verity',folder:'Audits'},{id:F,from:'verity',folder:'Audits'}]);
});
it('moves the whole subtree to another project and never re-roots a selected child',()=>{
 const plan=planMissionMoves([P,C,F],'other','Audits',known);
 expect(plan.map(s=>s.id)).toEqual([P,F,C,G]);
 expect(plan.find(s=>s.id===C)!.folder).toBe('');
});
it('moves two missions in parallel, and only the failed one rolls back',async()=>{
 resetMoves();
 vi.mocked(getMission).mockImplementation(async (id:string)=>({id,tags:['keep']}) as any);
 let release!:()=>void; const gate=new Promise<void>(r=>release=r); let inflight=0,peak=0;
 vi.mocked(api).mockImplementation(async (path:string)=>{ inflight++; peak=Math.max(peak,inflight); await gate; inflight--; if(path.includes(F)) throw new Error('busy'); return {} as any; });
 const done=moveMissions(planMissionMoves([P,F],'verity','Audits',known),'verity');
 await vi.waitFor(()=>expect(peak).toBe(2));
 expect([...pendingMoves().keys()].sort()).toEqual([`mission:${P}`,`mission:${F}`].sort());
 release();
 const failed=await done;
 expect(failed.map(f=>f.id)).toEqual([F]);
 expect(pendingMoves().has(`mission:${F}`)).toBe(false);
 expect(pendingMoves().get(`mission:${P}`)?.acceptedAt).toBeTypeOf('number');
 for (const call of vi.mocked(api).mock.calls) expect(JSON.parse(call[1]!.body as string).tags).toEqual(['keep','orb-folder:Audits']);
});
it('reads the running worker from Core’s 409 delete refusal',()=>{
 expect(runningWorkerIds(`Cannot delete a running mission or worker (${C}). Cancel it first.`)).toEqual([C]);
 expect(runningWorkerIds('Mission is locked')).toEqual([]);
});

import { deleteDescendants, descendantsSentence } from '../src/deleteRunning';
import { missionIdFromTreeId, missionTreeId } from '../src/tree/TreeView';
it('lists every session a delete takes with it, flagging running ones',()=>{
 const rows=[{id:'ev',title:'EV Bench',status:'completed'},{id:'b',title:'Benchmarks',status:'active',parent_mission_id:'ev'},{id:'btw',title:'EV Bench · btw',status:'completed',callback_parent_mission_id:'ev'},{id:'x',title:'Other',status:'active'}];
 const list=deleteDescendants(['ev'],rows);
 expect(list.map(d=>d.id)).toEqual(['b','btw']);
 expect(descendantsSentence(list)).toBe('This also deletes 2 sessions: Benchmarks (running), EV Bench · btw.');
 expect(descendantsSentence([])).toBe('');
 expect(descendantsSentence(Array.from({length:8},(_,i)=>({id:`${i}`,title:`S${i}`,running:false})),3)).toBe('This also deletes 8 sessions: S0, S1, S2, and 5 more.');
});
it('sets includeDescendants on cross-project and split-subtree root moves and executes a single atomic root write per subtree',async()=>{
 resetMoves();
 const CB='55555555-5555-5555-5555-555555555555';
 const crossKnown=[...known,{id:CB,project:'verity',callback_parent_mission_id:P}];
 const crossPlan=planMissionMoves([P],'other','Audits',crossKnown);
 expect(crossPlan[0]).toEqual({id:P,from:'verity',folder:'Audits',includeDescendants:true,descendantIds:[CB]});
 expect(crossPlan.slice(1).every(s=>s.viaRootId===P)).toBe(true);
 const splitKnown=[{id:P,project:'other'},{id:CB,project:'other',callback_parent_mission_id:P},{id:C,project:'verity',parent_mission_id:CB}];
 const healPlan=planMissionMoves([P],'other','',splitKnown);
 expect(healPlan).toEqual([
  {id:P,from:'other',folder:'',includeDescendants:true,descendantIds:[CB]},
  {id:C,from:'verity',folder:'',viaRootId:P},
 ]);
 vi.mocked(getMission).mockResolvedValue({id:P,tags:[]} as any);
 const movedEvents:Array<{id:string;project:string;tags?:string[]}>=[];
 const onMoved=(e:Event)=>movedEvents.push((e as CustomEvent).detail);
 window.addEventListener('orb:mission-moved',onMoved);
 let release!:()=>void; const gate=new Promise<void>(r=>{release=r;});
 vi.mocked(api).mockImplementation(async ()=>{ await gate; return {ok:true} as any; });
 const done=moveMissions(crossPlan,'other');
 await vi.waitFor(()=>expect(vi.mocked(api)).toHaveBeenCalledTimes(1));
 // Root and every descendant are projected optimistically while only 1 server write is in flight.
 expect([...pendingMoves().keys()].sort()).toEqual([P,C,G,CB].map(m=>`mission:${m}`).sort());
 release();
 expect(await done).toEqual([]);
 window.removeEventListener('orb:mission-moved',onMoved);
 expect(movedEvents.map(e=>e.id)).toEqual([P,C,G,CB]);
 expect(vi.mocked(api)).toHaveBeenCalledTimes(1);
 expect(JSON.parse(vi.mocked(api).mock.calls[0][1]!.body as string)).toEqual({
  project:'other',
  tags:['orb-folder:Audits'],
  include_descendants:true,
  descendant_ids:[CB],
 });

 // On failure (e.g. descendant track conflict rolled back on Core), root and all child projections roll back together.
 resetMoves();
 vi.clearAllMocks();
 vi.mocked(getMission).mockResolvedValue({id:P,tags:[]} as any);
 vi.mocked(api).mockRejectedValueOnce(new Error('writer_conflict'));
 const failed=await moveMissions(crossPlan,'other');
 expect(vi.mocked(api)).toHaveBeenCalledTimes(1);
 expect(failed.map(f=>f.id)).toEqual([P,C,G,CB]);
 expect(pendingMoves().size).toBe(0);
});
it('assigns distinct tree IDs to cross-project placeholder parents while resolving canonical mission IDs',()=>{
 expect(missionTreeId(P)).toBe(`m:${P}`);
 expect(missionTreeId(P,'verity-core')).toBe(`mp:verity-core:${P}`);
 expect(missionTreeId(P,'archive:verity-core')).toBe(`mp:archive:verity-core:${P}`);
 expect(missionIdFromTreeId(`m:${P}`)).toBe(P);
 expect(missionIdFromTreeId(`mp:verity-core:${P}`)).toBe(P);
 expect(missionIdFromTreeId(`mp:archive:verity-core:${P}`)).toBe(P);
 expect(missionIdFromTreeId('pf:verity-core:Audits')).toBeNull();
});
it('moves co-located fork-of versions and their Default children with the visible conversation leader, without touching individual version moves or cross-project forks',()=>{
 const V1='52bbf658-8705-4df7-8510-24dc69aed102';
 const V2='97399f01-c91d-4c44-b9ef-4a645f0e3333';
 const V3='5fc3a745-bcda-4bba-b0c4-42293e70184c';
 const V4='0c532a32-2fb5-4fd6-ba6b-b9820d12c097';
 const D1='d450d33d-1111-4111-8111-111111111111';
 const OTHER='66666666-6666-4666-8666-666666666666';
 const forkKnown=[
  {id:V1,project:'assistant',status:'completed',updated_at:'2026-10-28T00:00:00Z'},
  {id:D1,project:null,parent_mission_id:V1,status:'interrupted'},
  {id:V2,project:'assistant',tags:[`fork-of:${V1}`],status:'interrupted',updated_at:'2026-10-29T00:00:00Z'},
  {id:V3,project:'assistant',tags:[`fork-of:${V2}`],status:'completed',updated_at:'2026-10-29T12:00:00Z'},
  {id:V4,project:'assistant',tags:[`fork-of:${V2}`],status:'active',updated_at:'2026-10-30T01:00:00Z'},
  {id:OTHER,project:'elsewhere',tags:[`fork-of:${V1}`],status:'completed',updated_at:'2026-10-29T05:00:00Z'},
 ];
 // Moving the leading conversation row moves every co-located version in `assistant`
 // and heals V1's `project: null` (`Default`) child in the same operation.
 const leaderPlan=planMissionMoves([V4],'verity-core','evm',forkKnown);
 const rootIds=leaderPlan.filter(s=>!s.viaRootId).map(s=>s.id);
 expect(rootIds).toEqual([V4,V1,V2,V3]);
 expect(rootIds).not.toContain(OTHER);
 expect(leaderPlan.find(s=>s.id===D1)).toEqual({id:D1,from:null,folder:'',viaRootId:V1});

 // Explicitly moving a single earlier version row moves ONLY that version.
 const singleVersionPlan=planMissionMoves([V3],'verity-core','',forkKnown);
 expect(singleVersionPlan).toEqual([{id:V3,from:'assistant',folder:'',includeDescendants:true}]);
});
