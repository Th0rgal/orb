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
