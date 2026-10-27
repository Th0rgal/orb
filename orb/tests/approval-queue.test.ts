import {afterEach,describe,it,expect,vi} from 'vitest';
vi.mock('../src/api',()=>({api:vi.fn(),connectionVersion:()=>0}));
vi.mock('../src/deviceApproval',()=>({signedApi:vi.fn(),ApprovalCancelled:class extends Error{}}));
import {signedApi} from '../src/deviceApproval';
import fixture from '../../shared/orb-spec/fixtures/approvals.json';
import {MAX_BATCH,approveItems,batchApprovable,denyItem,itemDetail,itemRequester,itemTitle,queueSummary,signingReason,type ApprovalItem} from '../src/approvalQueue';
const item=(c:any,n=0):ApprovalItem=>({id:`i${n}`,reason:'',created_at:'',digest:`d${n}`,...c.item});
afterEach(()=>vi.mocked(signedApi).mockReset());
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
   expect(batchApprovable(items,false).length).toBe(s.without_critical);
   expect(batchApprovable(items,true).length).toBe(items.length);
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
  expect(batchApprovable(many,true).length).toBe(MAX_BATCH);
 });
 it('the device prompt names every item, critical first',()=>{
  const items=[0,9,2].map(k=>item(fixture.labels[k],k));
  expect(signingReason(items)).toBe('approve 3 requests (1 critical · 1 elevated · 1 routine): Move OLD_TOKEN; Service deploy on agent-core; Read OPENAI_API_KEY');
  expect(itemDetail(items[1],(id)=>({'3b1f9c2a-0000-4000-8000-00000000000a':'prod','8d2e4f6a-0000-4000-8000-00000000000b':'archive'} as any)[id])).toBe('From prod to archive');
 });
 it('denies through each kind\'s own route',async()=>{
  vi.mocked(signedApi).mockResolvedValue({});
  for(const k of [0,2,7]) await denyItem(item(fixture.labels[k],k));
  expect(vi.mocked(signedApi).mock.calls.map(c=>c[1])).toEqual(['/api/privilege-access/i0/deny','/api/bitwarden/requests/i2/reject','/api/mission-access/i7/deny']);
 });
});
