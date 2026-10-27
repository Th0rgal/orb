import {afterEach,describe,it,expect,vi} from 'vitest';
vi.mock('../src/api',()=>({api:vi.fn(),connectionVersion:()=>0,ApiError:class extends Error{constructor(public status:number,public detail:string){super(`${status} ${detail}`);}}}));
vi.mock('../src/deviceApproval',()=>({signedApi:vi.fn(),ApprovalCancelled:class extends Error{}}));
import {signedApi} from '../src/deviceApproval';
import {api,ApiError} from '../src/api';
import fixture from '../../shared/orb-spec/fixtures/approvals.json';
import {MAX_BATCH,approveItems,getApprovalQueue,legacyItem,riskOf,normalBatch,allBatch,denyItem,itemDetail,itemRequester,itemTitle,queueSummary,signingReason,type ApprovalItem} from '../src/approvalQueue';
const item=(c:any,n=0):ApprovalItem=>({id:`i${n}`,reason:'',created_at:'',digest:`d${n}`,...c.item});
afterEach(()=>{vi.mocked(signedApi).mockReset();vi.mocked(api).mockReset();});
describe('approval queue',()=>{
 it('labels every kind like iOS and Android',()=>{
  for(const c of fixture.labels){
   const i=item(c);
   expect([itemTitle(i),itemRequester(i),itemDetail(i)]).toEqual([c.title,c.requester,c.detail]);
  }
 });
 it('summarizes a batch and leaves critical items out unless ticked',()=>{
  for(const s of fixture.summaries){
   const items=s.items.map((k,n)=>item(fixture.labels[k],n));
   const q=queueSummary(items);
   expect([q.risks,q.missions]).toEqual([s.risks,s.missions]);
   expect(normalBatch(items).length).toBe(s.without_critical);
   expect(allBatch(items).length).toBe(items.length);
  }
 });
 it('signs kind, id and digest for each item, confirming critical only when one is listed',async()=>{
  vi.mocked(signedApi).mockResolvedValue({});
  const [deploy,root,read]=[item(fixture.labels[0],0),item(fixture.labels[1],1),item(fixture.labels[2],2)];
  await approveItems([deploy,read]);
  expect(vi.mocked(signedApi).mock.calls[0].slice(0,3)).toEqual(['POST','/api/approvals/approve-all',{items:[{kind:'privilege',id:'i0',digest:'d0'},{kind:'secret',id:'i2',digest:'d2'}],confirm_critical:false}]);
  await approveItems([root]);
  expect((vi.mocked(signedApi).mock.calls[1][2] as any).confirm_critical).toBe(true);
  expect(vi.mocked(signedApi).mock.calls[1][3]).toBe('Root on its own node for Mission 9a8b7c6d');
 });
 it('never asks Core for more than one signature can approve',()=>{
  const many=Array.from({length:MAX_BATCH+5},(_,n)=>item(fixture.labels[2],n));
  expect(allBatch(many).length).toBe(MAX_BATCH);
  expect(normalBatch(many).length).toBe(MAX_BATCH);
 });
 it('the device prompt names every item, critical first',()=>{
  const items=[0,9,2].map(k=>item(fixture.labels[k],k));
  expect(signingReason(items)).toBe('approve 3 requests (1 critical · 1 elevated · 1 routine): Move OLD_TOKEN; Service deploy on agent-core; Read OPENAI_API_KEY');
  expect(itemDetail(items[1],(id)=>({'3b1f9c2a-0000-4000-8000-00000000000a':'prod','8d2e4f6a-0000-4000-8000-00000000000b':'archive'} as any)[id])).toBe('From prod to archive');
 });
 it('assigns risk like Core (approvals.json risk table)',()=>{
  for(const c of fixture.risk as any[]) expect(riskOf(c.kind,c.tier,{all_projects:c.all_projects===true})).toBe(c.risk);
 });
 it('falls back to the per-kind lists when Core has no queue, and one failing list hides nothing else',async()=>{
  const priv={id:'p1',state:'pending',scope:'service_deploy',target_host:'agent-core',requester_mission_id:'m1',requester_title:'Ship usage fix',reason:'deploy',ttl_minutes:240,session_scoped:true,created_at:'2026-10-27T10:00:00Z'};
  const access={id:'a1',state:'pending',scope:'read',requester_mission_id:'m2',requester_title:'Fleet health',target_mission_id:'t1',target_title:'Disk cleanup',reason:'r',ttl_hours:24,created_at:'2026-10-27T09:00:00Z'};
  vi.mocked(api).mockImplementation(async(path:string)=>{
   if(path==='/api/approvals/queue')throw new (ApiError as any)(404,'Not Found');
   if(path==='/api/privilege-access')return {bunker_state:0,requests:[priv,{...priv,id:'p0',state:'approved'}],audit:[],command_audit:[]};
   if(path==='/api/bitwarden/broker')throw new Error('Bitwarden is not configured');
   if(path==='/api/mission-access')return {requests:[access],audit:[]};
   throw new Error(path);
  });
  const {items}=await getApprovalQueue();
  expect(items.map(i=>[i.kind,i.id,i.risk,itemTitle(i),itemRequester(i),i.legacy])).toEqual([
   ['privilege','p1','elevated','Service deploy on agent-core','Ship usage fix',true],
   ['mission_access','a1','elevated','Read Disk cleanup','Fleet health',true],
  ]);
  expect(itemDetail(items[0])).toBe('Allows restart and deploy services, including production · for this session (max 4 h)');
 });
 it('"Approve N" covers the normal items only; "Approve all" covers everything, critical first',()=>{
  const root=legacyItem('privilege',{id:'p1',state:'pending',scope:'root_exec',target_host:'self',requester_mission_id:'m1',reason:'x',ttl_minutes:60,session_scoped:true,created_at:''} as any);
  const read=legacyItem('privilege',{id:'p2',state:'pending',scope:'ops_read',target_host:'ashur',requester_mission_id:'m1',reason:'x',ttl_minutes:60,session_scoped:true,created_at:''} as any);
  expect(normalBatch([read,root]).map(i=>i.id)).toEqual(['p2']);
  expect(allBatch([read,root]).map(i=>i.id)).toEqual(['p1','p2']);
 });
 it('only a missing queue falls back; other errors keep what the client shows',async()=>{
  vi.mocked(api).mockRejectedValue(new (ApiError as any)(503,'Service Unavailable'));
  await expect(getApprovalQueue()).rejects.toThrow('503');
 });
 it('approves legacy items through each kind\'s own signed route',async()=>{
  vi.mocked(signedApi).mockResolvedValue({});
  await approveItems([
   legacyItem('privilege',{id:'p1',state:'pending',scope:'root_exec',target_host:'self',requester_mission_id:'m1',reason:'x',ttl_minutes:60,session_scoped:true,created_at:''} as any),
   legacyItem('secret',{id:'s1',status:'pending',kind:'read',mission_id:'m1',key:'K',all_projects:false,reason:'x',created_at:''} as any),
   legacyItem('mission_access',{id:'a1',state:'pending',scope:'read',requester_mission_id:'m2',target_mission_id:'t1',reason:'r',ttl_hours:24,created_at:''} as any),
  ]);
  expect(vi.mocked(signedApi).mock.calls.map(c=>[c[1],c[2]])).toEqual([
   ['/api/privilege-access/p1/approve',{ttl_minutes:60,session_scoped:true}],
   ['/api/bitwarden/requests/s1/approve',{scope:undefined,ttl_hours:undefined}],
   ['/api/mission-access/a1/approve',{ttl_hours:24}],
  ]);
 });
 it('denies through each kind\'s own route',async()=>{
  vi.mocked(signedApi).mockResolvedValue({});
  for(const k of [0,2,7]) await denyItem(item(fixture.labels[k],k));
  expect(vi.mocked(signedApi).mock.calls.map(c=>c[1])).toEqual(['/api/privilege-access/i0/deny','/api/bitwarden/requests/i2/reject','/api/mission-access/i7/deny']);
 });
});
