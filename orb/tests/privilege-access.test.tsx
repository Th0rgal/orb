import {render,screen,fireEvent,cleanup,waitFor} from '@solidjs/testing-library';
import {afterEach,describe,it,expect,vi} from 'vitest';
vi.mock('../src/api',()=>({api:vi.fn(),connectionVersion:()=>0}));
vi.mock('../src/deviceApproval',()=>({signedApi:vi.fn(),ApprovalCancelled:class extends Error{}}));
import {api} from '../src/api';
import {signedApi} from '../src/deviceApproval';
import fixture from '../../shared/orb-spec/fixtures/privilege-access.json';
import {approveAllPrivilegeAccess,batchApprovable,batchSummary,requestTitle,requesterLabel,approvePrivilegeAccess,denyPrivilegeAccess,lifetimeLabel,livePrivilegeGrant,revokePrivilegeAccess,scopeUnlocks,type PrivilegeRequest} from '../src/privilegeAccessApi';
import {PrivilegeAccessPanel} from '../src/PrivilegeAccessPanel';
const now=Date.now();
const iso=(ms:number)=>new Date(now+ms).toISOString();
const req=(over:Partial<PrivilegeRequest>={}):PrivilegeRequest=>({id:'p1',requester_mission_id:'7c1d2e3f-0000-4000-8000-000000000001',requester_title:'Deploy orb',target_host:'agent-core',scope:'service_deploy',allowed_unit:null,reason:'Ship the fix',session_scoped:true,ttl_minutes:240,state:'pending',created_at:iso(-60_000),...over});
afterEach(()=>{vi.mocked(api).mockReset();vi.mocked(signedApi).mockReset();cleanup();});
describe('privilege access',()=>{
 it('describes what a grant unlocks and for how long',()=>{
  expect(scopeUnlocks(req())).toContain('production');
  expect(scopeUnlocks(req({allowed_unit:'orb-core.service'}))).toBe('restart and deploy orb-core.service only');
  expect(scopeUnlocks(req({scope:'root_exec'}))).toBe('any command as root');
  expect(lifetimeLabel(req())).toBe('for this session (max 4 h)');
  expect(lifetimeLabel(req({session_scoped:false,ttl_minutes:30}))).toBe('for 30 min');
 });
 it('matches the shared fixture used by iOS and Android',()=>{
  for(const c of fixture.cases){
   const r=req(c.request as Partial<PrivilegeRequest>);
   expect([requestTitle(r),scopeUnlocks(r),lifetimeLabel(r),requesterLabel(r)]).toEqual([c.title,c.unlocks,c.lifetime,c.requester]);
  }
 });
 it('summarizes an "Approve all" batch like iOS and Android, and leaves root out unless confirmed',()=>{
  for(const b of fixture.batches){
   const rs=b.requests.map((i,n)=>req({...(fixture.cases[i].request as Partial<PrivilegeRequest>),id:`b${n}`}));
   const s=batchSummary(rs);
   expect([s.tiers,s.hosts,s.missions,s.root]).toEqual([b.tiers,b.hosts,b.missions,b.root]);
   expect(batchApprovable(rs,false).length).toBe(b.without_root);
   expect(batchApprovable(rs,true).length).toBe(rs.length);
  }
 });
 it('signs one challenge that lists every request with its host, tier and mission',async()=>{
  vi.mocked(signedApi).mockResolvedValue([]);
  const rs=[req(),req({id:'p2',scope:'root_exec',target_host:'self',requester_mission_id:'m2',ttl_minutes:60,session_scoped:false,allowed_unit:null})];
  await approveAllPrivilegeAccess(rs);
  const [method,path,body,summary]=vi.mocked(signedApi).mock.calls[0];
  expect([method,path]).toEqual(['POST','/api/privilege-access/approve-all']);
  expect(body).toEqual({confirm_root:true,items:[
   {id:'p1',requester_mission_id:'7c1d2e3f-0000-4000-8000-000000000001',target_host:'agent-core',scope:'service_deploy',allowed_unit:null,ttl_minutes:240,session_scoped:true},
   {id:'p2',requester_mission_id:'m2',target_host:'self',scope:'root_exec',allowed_unit:null,ttl_minutes:60,session_scoped:false},
  ]});
  expect(summary).toContain('1 Root · 1 Service deploy');
  await approveAllPrivilegeAccess([req()]);
  expect((vi.mocked(signedApi).mock.calls[1][2] as any).confirm_root).toBe(false);
 });
 it('approves all non-root pending requests from settings, root only when ticked',async()=>{
  vi.mocked(signedApi).mockResolvedValue([]);
  render(()=><PrivilegeAccessPanel onError={()=>{}} initial={{bunker_state:0,requests:[req(),req({id:'p2',scope:'ops_read',target_host:'ashur'}),req({id:'p3',scope:'root_exec',target_host:'self'})],audit:[],command_audit:[]}}/>);
  expect(screen.getByTestId('privilege-batch-summary').textContent).toContain('1 Root · 1 Service deploy · 1 Read-only ops');
  fireEvent.click(screen.getByRole('button',{name:'Approve 2'}));
  await waitFor(()=>expect(vi.mocked(signedApi)).toHaveBeenCalledTimes(1));
  expect((vi.mocked(signedApi).mock.calls[0][2] as any).items.map((i:any)=>i.id)).toEqual(['p1','p2']);
  await waitFor(()=>expect((screen.getByRole('button',{name:'Approve 2'}) as HTMLButtonElement).disabled).toBe(false));
  fireEvent.click(screen.getByRole('checkbox'));
  fireEvent.click(screen.getByRole('button',{name:'Approve all'}));
  await waitFor(()=>expect(vi.mocked(signedApi)).toHaveBeenCalledTimes(2));
  expect((vi.mocked(signedApi).mock.calls[1][2] as any).items.map((i:any)=>i.id)).toEqual(['p1','p2','p3']);
 });
 it('treats only approved, unexpired, unrevoked grants as live',()=>{
  expect(livePrivilegeGrant(req())).toBe(false);
  expect(livePrivilegeGrant(req({state:'approved',expires_at:iso(60_000)}))).toBe(true);
  expect(livePrivilegeGrant(req({state:'approved',expires_at:iso(-1)}))).toBe(false);
  expect(livePrivilegeGrant(req({state:'approved',expires_at:iso(60_000),revoked_at:iso(-1)}))).toBe(false);
 });
 it('approves and denies through the signed (Touch ID) path, revokes unsigned',async()=>{
  vi.mocked(signedApi).mockResolvedValue(req({state:'approved'}));
  vi.mocked(api).mockResolvedValue(req({state:'revoked'}));
  await approvePrivilegeAccess(req());
  expect(vi.mocked(signedApi).mock.calls[0].slice(0,3)).toEqual(['POST','/api/privilege-access/p1/approve',{ttl_minutes:240,session_scoped:true}]);
  await denyPrivilegeAccess(req());
  expect(vi.mocked(signedApi).mock.calls[1].slice(0,3)).toEqual(['POST','/api/privilege-access/p1/deny',undefined]);
  await revokePrivilegeAccess('p1');
  expect(vi.mocked(api).mock.calls[0]).toEqual(['/api/privilege-access/p1',{method:'DELETE'}]);
 });
 it('lists pending requests and live grants in settings',async()=>{
  vi.mocked(signedApi).mockResolvedValue(req({state:'approved'}));
  render(()=><PrivilegeAccessPanel onError={()=>{}} initial={{bunker_state:0,requests:[req(),req({id:'g1',state:'approved',scope:'root_exec',target_host:'self',decided_at:iso(-60_000),expires_at:iso(3_600_000)})],audit:[],command_audit:[]}}/>);
  expect(screen.getByText('Service deploy on agent-core')).toBeTruthy();
  expect(screen.getByTestId('privilege-access-grant').textContent).toContain('Root on its own node');
  fireEvent.click(screen.getByRole('button',{name:'Allow'}));
  await waitFor(()=>expect(vi.mocked(signedApi)).toHaveBeenCalled());
 });
});
