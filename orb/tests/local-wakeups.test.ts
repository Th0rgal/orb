import {afterEach,beforeEach,expect,it,vi} from 'vitest';
const mocks=vi.hoisted(()=>({version:1,invoke:vi.fn(),capture:vi.fn(),confirm:vi.fn()}));
vi.mock('../src/api',()=>({connectionVersion:()=>mocks.version,getApiUrl:()=> 'http://core.test',getJwt:()=> 'owner'}));
vi.mock('../src/clientRuns',()=>({nativeInvoke:()=>mocks.invoke}));
vi.mock('../src/localMessageQueue',()=>({replayWakeupStops:async(replay:(mission:string,token:string)=>Promise<unknown>,valid:()=>boolean)=>{const fences=await mocks.capture();if(valid())for(const [mission,fence] of Object.entries(fences) as [string,{blocked:boolean;token:string}][])if(fence.blocked)await replay(mission,fence.token);},confirmWakeupStops:mocks.confirm}));
import {startLocalWakeups} from '../src/localWakeups';
let stop:(()=>void)|undefined;
beforeEach(()=>{vi.useFakeTimers();mocks.version=1;mocks.capture.mockReset().mockResolvedValue({mission:{token:'persisted-stop',blocked:true}});mocks.confirm.mockReset();mocks.invoke.mockReset().mockImplementation(async(command:string)=>command==='local_wakeups_sync'?{pending:[],changed:false,cancelled:[{mission:'mission',token:'persisted-stop'}]}:undefined);});
afterEach(()=>{stop?.();vi.useRealTimers();});
it('recovers the durable Stop fence when the native cancellation write was lost',async()=>{
 stop=startLocalWakeups();await vi.advanceTimersByTimeAsync(1);
 expect(mocks.invoke.mock.calls.map(c=>c[0])).toEqual(['local_wakeups_cancel','local_wakeups_sync']);
 expect(mocks.invoke.mock.calls[0][1]).toMatchObject({mission:'mission',cancelToken:'persisted-stop'});
 expect(mocks.confirm).toHaveBeenCalledWith([{mission:'mission',token:'persisted-stop'}]);
});
it('retries an interrupted Stop with the same token before syncing schedules',async()=>{
 mocks.invoke.mockRejectedValueOnce(new Error('native unavailable'));
 stop=startLocalWakeups();await vi.advanceTimersByTimeAsync(1);
 expect(mocks.confirm).not.toHaveBeenCalled();expect(mocks.invoke).toHaveBeenCalledTimes(1);
 await vi.advanceTimersByTimeAsync(5000);
 expect(mocks.invoke.mock.calls.map(c=>c[0])).toEqual(['local_wakeups_cancel','local_wakeups_cancel','local_wakeups_sync']);
 expect(mocks.invoke.mock.calls[1][1].cancelToken).toBe('persisted-stop');
});
it('does not replay a Stop into a changed connection',async()=>{
 let release!:(value:unknown)=>void;mocks.capture.mockImplementation(()=>new Promise(resolve=>release=resolve));
 stop=startLocalWakeups();await vi.advanceTimersByTimeAsync(1);mocks.version=2;
 release({mission:{token:'old-stop',blocked:true}});await vi.advanceTimersByTimeAsync(1);
 expect(mocks.invoke).not.toHaveBeenCalled();
});
