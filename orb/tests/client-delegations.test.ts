import {afterEach,beforeEach,expect,it,vi} from 'vitest';
const mocks=vi.hoisted(()=>({api:vi.fn(),enqueue:vi.fn(),directory:vi.fn(),remember:vi.fn(),failure:vi.fn(),version:1}));
vi.mock('../src/api',()=>({api:mocks.api,connectionVersion:()=>mocks.version}));
vi.mock('../src/clientRuns',()=>({nativeInvoke:()=>true,machineIdentity:async()=> 'computer'}));
vi.mock('../src/localMessageQueue',()=>({enqueueLocalMessage:mocks.enqueue}));
vi.mock('../src/localAgents',()=>({localBinding:()=>undefined,localDirectory:mocks.directory,recordLocalFailure:mocks.failure,rememberBinding:mocks.remember,restoreLocalBindings:async()=>{},refreshLocalAgents:async()=>[{id:'codex',path:'/bin/codex',installed:true}]}));
import {startClientDelegations} from '../src/clientDelegations';
let stop:()=>void;
const mission={id:'child',parent_mission_id:'parent',tags:['placement:client','worker-client:computer'],working_directory:'/plain',backend:'codex'};
beforeEach(()=>{vi.useFakeTimers();vi.clearAllMocks();mocks.version=1;mocks.remember.mockResolvedValue(undefined);mocks.directory.mockResolvedValue('/plain');mocks.enqueue.mockResolvedValue(undefined);mocks.api.mockImplementation(async(_path,options)=>JSON.parse(options.body).op==='inbox_all'?{messages:[{id:'message',content:'Do the task'}]}:{});});
afterEach(()=>{stop?.();vi.useRealTimers();});
it('persists a delegated task before acknowledging the server',async()=>{
 stop=startClientDelegations(()=>[mission] as never);await vi.advanceTimersByTimeAsync(1);
 expect(mocks.directory).toHaveBeenCalledWith('/plain');
 expect(mocks.enqueue).toHaveBeenCalledWith(expect.objectContaining({id:'child',cwd:'/plain',prompt:'Do the task'}),'Do the task',expect.objectContaining({id:'message',delegated:true}));
 const acknowledgement=mocks.api.mock.calls.findIndex(c=>JSON.parse(c[1].body).op==='received');
 expect(acknowledgement).toBeGreaterThan(-1);
 expect(mocks.enqueue.mock.invocationCallOrder[0]).toBeLessThan(mocks.api.mock.invocationCallOrder[acknowledgement]);
});
it('leaves the server message pending and displays an invalid directory',async()=>{
 mocks.directory.mockRejectedValue(new Error('Directory does not exist'));
 stop=startClientDelegations(()=>[mission] as never);await vi.advanceTimersByTimeAsync(1);
 expect(mocks.failure).toHaveBeenCalledWith('child',expect.any(Error));
 expect(mocks.enqueue).not.toHaveBeenCalled();
 expect(mocks.api.mock.calls.some(c=>JSON.parse(c[1].body).op==='received')).toBe(false);
});
it('does not acknowledge a failed local durable write',async()=>{
 mocks.enqueue.mockRejectedValue(new Error('disk full'));
 stop=startClientDelegations(()=>[mission] as never);await vi.advanceTimersByTimeAsync(1);
 expect(mocks.api.mock.calls.some(c=>JSON.parse(c[1].body).op==='received')).toBe(false);
});
it('does not accept tasks owned by another computer',async()=>{
 stop=startClientDelegations(()=>[{...mission,tags:['placement:client','worker-client:other']}] as never);await vi.advanceTimersByTimeAsync(1);
 expect(mocks.api).not.toHaveBeenCalled();
});

it('uses one inbox request for multiple workers',async()=>{
 stop=startClientDelegations(()=>[mission,{...mission,id:'another'}] as never);await vi.advanceTimersByTimeAsync(1);
 expect(mocks.api.mock.calls.filter(c=>JSON.parse(c[1].body).op==='inbox_all')).toHaveLength(1);
});

it('waits for the binding write before saving or acknowledging work',async()=>{
 let saved!:()=>void;
 mocks.remember.mockImplementation(()=>new Promise<void>(resolve=>{saved=resolve;}));
 stop=startClientDelegations(()=>[mission] as never);await vi.advanceTimersByTimeAsync(1);
 expect(mocks.enqueue).not.toHaveBeenCalled();
 expect(mocks.api.mock.calls.some(c=>JSON.parse(c[1].body).op==='received')).toBe(false);
 saved();await vi.advanceTimersByTimeAsync(1);
 expect(mocks.enqueue).toHaveBeenCalled();
 expect(mocks.api.mock.calls.some(c=>JSON.parse(c[1].body).op==='received')).toBe(true);
});
it('keeps delivery pending when binding persistence fails',async()=>{
 mocks.remember.mockRejectedValue(new Error('binding disk full'));
 stop=startClientDelegations(()=>[mission] as never);await vi.advanceTimersByTimeAsync(1);
 expect(mocks.failure).toHaveBeenCalledWith('child',expect.any(Error));
 expect(mocks.enqueue).not.toHaveBeenCalled();
 expect(mocks.api.mock.calls.some(c=>JSON.parse(c[1].body).op==='received')).toBe(false);
});
