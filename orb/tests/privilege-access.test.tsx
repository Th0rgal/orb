import {render,screen,fireEvent,cleanup,waitFor} from '@solidjs/testing-library';
import {afterEach,describe,it,expect,vi} from 'vitest';
vi.mock('../src/api',()=>({api:vi.fn(),connectionVersion:()=>0}));
vi.mock('../src/deviceApproval',()=>({signedApi:vi.fn(),ApprovalCancelled:class extends Error{}}));
import {api} from '../src/api';
import {signedApi} from '../src/deviceApproval';
import fixture from '../../shared/orb-spec/fixtures/privilege-access.json';
import {requestTitle,requesterLabel,approvePrivilegeAccess,bunkerStateLabel,denyPrivilegeAccess,lifetimeLabel,livePrivilegeGrant,revokePrivilegeAccess,scopeUnlocks,triggerBunker,unbunkerFleet,type PrivilegeRequest} from '../src/privilegeAccessApi';
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
 it('triggers and exits Bunker Mode through the signed (Touch ID) path',async()=>{
  vi.mocked(signedApi).mockResolvedValue({status:'bunkered',bunker_state:2});
  expect(bunkerStateLabel(0)).toBe('Normal');
  expect(bunkerStateLabel(2)).toBe('Hard Lockdown');
  await triggerBunker(2,'Canary manual test');
  expect(vi.mocked(signedApi).mock.calls[0].slice(0,3)).toEqual(['POST','/api/privilege-access/bunker',{level:2,reason:'Canary manual test',canary_tripped:true,auth_failure_burst:false}]);
  await unbunkerFleet();
  expect(vi.mocked(signedApi).mock.calls[1].slice(0,3)).toEqual(['POST','/api/privilege-access/unbunker',undefined]);
 });
});
