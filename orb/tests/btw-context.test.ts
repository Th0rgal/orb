import {it,expect,vi,afterEach} from 'vitest';
import {contextSnapshot,publicEvents,conversationEvents,prepareBtwContext} from '../src/btwContext';
import type {Mission} from '../src/api';
import {api} from '../src/api';
import {transferFile} from '../src/uploads';
vi.mock('../src/localAgents',()=>({writeLocalFiles:vi.fn(async()=>{})}));
vi.mock('../src/api',()=>({api:vi.fn()}));
vi.mock('../src/uploads',async original=>({...await original<typeof import('../src/uploads')>(),transferFile:vi.fn(async(source:any,destination:string)=>({path:`/${destination}/uploads/00000000-0000-0000-0000-000000000001/${source.name}`}))}));
const source={id:'parent',title:'Verity',status:'active',history:[{role:'user',content:'Objective '+ 'x'.repeat(100000)}]} as Mission;
const event=(sequence:number,event_type='assistant_message',content='progress')=>({id:sequence,sequence,event_type,content,timestamp:''});
afterEach(()=>vi.clearAllMocks());
it('sends bounded initial context then only new public events, without replaying side history',async()=>{
 const first=await contextSnapshot(source,[event(1)],'Recent progress');
 const second=await contextSnapshot(source,[event(1),event(2,'tool_result','New result')],'Recent progress',first.cursor);
 expect(second.summary).toContain('New result');expect(second.summary).not.toContain('[1]');expect(second.summary).not.toContain('Objective');
 const same=await contextSnapshot(source,[event(1),event(2,'tool_result','New result')],'Recent progress',second.cursor);
 expect(same.summary).toContain('No new public events');expect(same.summary).not.toContain('Recent progress');
 const huge=await contextSnapshot(source,[event(2,'assistant_message','Slice 15 summary: 241/462 covered'),...Array.from({length:20},(_,i)=>event(3+i,'tool_result','é'.repeat(5000)))],'é'.repeat(100000),first.cursor);
 expect(huge.summary).toContain('Slice 15 summary: 241/462 covered');
 expect(new TextEncoder().encode(huge.summary).length).toBeLessThan(6500);
});
it('excludes private reasoning, queued drafts and metadata from files',()=>{
 const rows=publicEvents([event(1,'thinking','private'),{...event(2,'user_message','draft'),metadata:{queued:true}}, {...event(3,'tool_result','actual'),metadata:{private:'secret'}}]);
 expect(rows).toEqual([event(3,'tool_result','actual')]);expect(JSON.stringify(rows)).not.toMatch(/private|draft|secret/);
});
it('paginates the entire fixed snapshot, not just the latest 4000 events',async()=>{
 vi.mocked(api).mockResolvedValueOnce([event(3),event(4)]).mockResolvedValueOnce([event(1),event(2)]).mockResolvedValueOnce([]);
 expect((await conversationEvents('parent')).map(e=>e.sequence)).toEqual([1,2,3,4]);
 expect(vi.mocked(api).mock.calls[1][0]).toContain('before_seq=3');expect(vi.mocked(api).mock.calls[2][0]).toContain('before_seq=1');
});
it('uploads readable archives to the selected machine and returns their manifest, not inline history',async()=>{
 vi.mocked(api).mockResolvedValueOnce([event(1,'tool_result','full details')]).mockResolvedValueOnce([]);
 const result=await prepareBtwContext(source,'Latest','old-agent');
 expect(result.context).toContain('@conversation: .paloma/conversation/00000000-0000-0000-0000-000000000001/conversation.json');
 expect(result.context).not.toContain('x'.repeat(100));
 const calls=vi.mocked(transferFile).mock.calls;
 expect(calls).toHaveLength(3);expect(calls.every(c=>c[1]==='old-agent')).toBe(true);
});
it('resets the cursor when an event log is replaced',async()=>{
 const result=await contextSnapshot(source,[event(1)],'Now',{sequence:100,visibleHash:'old'});
 expect(result.summary).toContain('Initial recent context');
});
it('reuses the archive when no events or visible text changed',async()=>{
 vi.mocked(api).mockResolvedValueOnce([event(1)]).mockResolvedValueOnce([]);
 const first=await prepareBtwContext(source,'Latest','old-agent');
 vi.mocked(api).mockResolvedValueOnce([event(1)]);
 const second=await prepareBtwContext(source,'Latest','old-agent',first.cursor);
 expect(transferFile).toHaveBeenCalledTimes(3);
 expect(second.cursor.archive).toBe(first.cursor.archive);
 expect(second.context).toContain('No new public events.');
});
it('stops paginating at previous.sequence and reuses the staged archive when new events arrive',async()=>{
 vi.mocked(api).mockResolvedValueOnce([event(1),event(2)]).mockResolvedValueOnce([]);
 const first=await prepareBtwContext(source,'Latest','old-agent');
 expect(vi.mocked(api)).toHaveBeenCalledTimes(2);
 expect(transferFile).toHaveBeenCalledTimes(3);
 vi.mocked(api).mockResolvedValueOnce([event(2),event(3,'tool_result','fresh update')]);
 const second=await prepareBtwContext(source,'Latest','old-agent',first.cursor);
 expect(vi.mocked(api)).toHaveBeenCalledTimes(3);
 expect(transferFile).toHaveBeenCalledTimes(3);
 expect(second.cursor.archive).toBe(first.cursor.archive);
 expect(second.cursor.sequence).toBe(3);
 expect(second.context).toContain('New events after 2 through 3');
 expect(second.context).toContain('fresh update');
});
it('preserves large Unicode tool results byte-for-byte across bounded archive parts',async()=>{
 const {File}=await import('node:buffer');vi.stubGlobal('File',File);
 try {
  const content='🕊'.repeat(2200000);
  vi.mocked(api).mockResolvedValueOnce([event(1,'tool_result',content)]).mockResolvedValueOnce([]);
  await prepareBtwContext(source,'Latest','core');
  const files=vi.mocked(transferFile).mock.calls.map(([s])=>s.file!);
  const parts=files.filter(f=>f.name.startsWith('events.jsonl'));
  expect(parts.length).toBeGreaterThan(1);expect(parts.every(f=>f.size<=8*1024*1024)).toBe(true);
  const restored=JSON.parse((await Promise.all(parts.map(f=>f.text()))).join(''));
  expect(restored.content).toBe(content);
  const manifest=JSON.parse(await files.find(f=>f.name==='conversation.json')!.text());
  expect(manifest.event_parts).toHaveLength(parts.length);
 }finally{vi.unstubAllGlobals();}
});

it('writes local archives inside the owning workspace without external uploads',async()=>{
 const {File}=await import('node:buffer');vi.stubGlobal('File',File);
 try {
  const {writeLocalFiles}=await import('../src/localAgents');
  vi.mocked(api).mockResolvedValueOnce([event(1)]).mockResolvedValueOnce([]);
  const result=await prepareBtwContext(source,'Latest','local',undefined,[],'/owned/workspace');
  expect(transferFile).not.toHaveBeenCalled();
  expect(result.cursor.archive).toMatch(/^\.paloma\/conversation\/[0-9a-f-]+\/conversation.json$/);
  expect(writeLocalFiles).toHaveBeenCalledTimes(3);
  expect(vi.mocked(writeLocalFiles).mock.calls.every(([root,files])=>root==='/owned/workspace'&&files.every(f=>f.rel.startsWith('.paloma/conversation/')))).toBe(true);
 }finally{vi.unstubAllGlobals();}
});
