import {render,screen,fireEvent,cleanup,waitFor} from '@solidjs/testing-library';
import {afterEach,describe,it,expect,vi} from 'vitest';
vi.mock('../src/api',()=>({api:vi.fn(),connectionVersion:()=>0}));
vi.mock('../src/deviceApproval',()=>({signedApi:vi.fn(),ApprovalCancelled:class extends Error{},approvalGraceSecs:()=>300,graceUntil:()=>0,setApprovalGraceSecs:vi.fn()}));
import {api} from '../src/api';
import {signedApi} from '../src/deviceApproval';
import fixture from '../../shared/orb-spec/fixtures/privilege-access.json';
import {requestTitle,requesterLabel,approvePrivilegeAccess,bunkerStateLabel,denyPrivilegeAccess,lifetimeLabel,livePrivilegeGrant,revokePrivilegeAccess,scopeUnlocks,triggerBunker,unbunkerFleet,type PrivilegeRequest} from '../src/privilegeAccessApi';
import {PrivilegeAccessPanel} from '../src/PrivilegeAccessPanel';
import {MissionAccessPanel} from '../src/MissionAccessPanel';
import {SecretAccessPanel} from '../src/SecretAccessPanel';
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
  it('renders external-session requests, grants and audits across privilege, mission and secret panels without mission_id',async()=>{
   const extSubject={kind:'external_session' as const,session_id:'c4d5e6f7-0000-4000-8000-000000000099',client_kind:'local_mcp' as const,client_label:'claude-code',host_hint:'macbook-air'};
   render(()=><PrivilegeAccessPanel onError={()=>{}} initial={{bunker_state:0,requests:[req({id:'px',requester_mission_id:null,requester_title:null,requester:extSubject,scope:'ops_read',target_host:'dgx-spark'})],audit:[],command_audit:[{id:'cx',at:iso(-10_000),grant_id:'gx',mission_id:null,requester:extSubject,target_host:'dgx-spark',scope:'ops_read',command:'systemctl status'}]}}/>);
   expect(screen.getByText(/External · macbook-air \(claude-code\)/)).toBeTruthy();
   cleanup();
   render(()=><MissionAccessPanel onError={()=>{}} initial={{requests:[{id:'mx',requester_mission_id:null,requester:extSubject,requester_title:null,target_mission_id:'9a8b7c6d-0000-4000-8000-000000000002',target_title:'Lean eval',scope:'read',reason:'inspect',ttl_hours:24,state:'pending',created_at:iso(-30_000)}],audit:[{at:iso(-5_000),request_id:'mx',requester_mission_id:null,requester:extSubject,target_mission_id:'9a8b7c6d-0000-4000-8000-000000000002',action:'requested'}]}}/>);
   expect(screen.getByText(/External · macbook-air \(claude-code\)/)).toBeTruthy();
   fireEvent.click(screen.getByRole('button',{name:/Show activity/}));
   expect(screen.getAllByText(/External · macbook-air \(claude-code\)/).length).toBeGreaterThanOrEqual(2);
   cleanup();
   vi.mocked(api).mockResolvedValue({requests:[{id:'sx',kind:'read',status:'pending',mission_id:null,requester:extSubject,all_projects:false,key:'OPENAI_API_KEY',reason:'local cli',created_at:iso(-20_000)}],grants:[{id:'sg1',mission_id:null,requester:extSubject,scope:{kind:'secret',key:'OPENAI_API_KEY'},created_at:iso(-60_000),expires_at:iso(3_600_000)}],audit:[{at:iso(-10_000),mission_id:null,requester:extSubject,key:'OPENAI_API_KEY',via:'grant'}]});
   render(()=><SecretAccessPanel projects={[]} requireBiometric={async()=>true} onError={()=>{}} onSecretsChanged={()=>{}}/>);
   await waitFor(()=>expect(screen.getByText(/External · macbook-air \(claude-code\)/)).toBeTruthy());
  });
});
