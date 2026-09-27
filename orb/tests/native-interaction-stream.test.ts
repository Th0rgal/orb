import {afterEach,describe,expect,it,vi} from 'vitest';
import {followInteraction} from '../src/nativeInteractionStream';
const host=window as any;
const oldNative=host.__TAURI_INTERNALS__,oldTauri=host.__TAURI__;
afterEach(()=>{host.__TAURI_INTERNALS__=oldNative;host.__TAURI__=oldTauri;vi.useRealTimers();});
function setup(invoke:ReturnType<typeof vi.fn>) {
 let channel:any;
 host.__TAURI_INTERNALS__={invoke};
 host.__TAURI__={core:{Channel:class {onmessage=()=>{};constructor(){channel=this;}}}};
 return ()=>channel;
}
describe('native interaction subscription',()=>{
 it('receives snapshots and changes without polling and releases its subscription',async()=>{
  vi.useFakeTimers();const invoke=vi.fn(async()=>7);const channel=setup(invoke),publish=vi.fn(),fail=vi.fn();
  const stop=followInteraction('mission',publish,fail);
  await Promise.resolve();channel().onmessage(null);channel().onmessage({id:'request'});
  await vi.advanceTimersByTimeAsync(60000);
  expect(invoke).toHaveBeenCalledTimes(1);expect(invoke.mock.calls[0][0]).toBe('local_interaction_subscribe');
  expect(publish.mock.calls).toEqual([[null],[{id:'request'}]]);
  stop();expect(invoke).toHaveBeenLastCalledWith('local_interaction_unsubscribe',{id:'mission',token:7});
  channel().onmessage(null);expect(publish).toHaveBeenCalledTimes(2);expect(fail).not.toHaveBeenCalled();
 });
 it('unsubscribes if registration completes after the view was disposed',async()=>{
  let resolve!:(value:number)=>void;const invoke=vi.fn().mockImplementationOnce(()=>new Promise(r=>resolve=r)).mockResolvedValue(undefined);
  setup(invoke);const stop=followInteraction('old',vi.fn(),vi.fn());stop();resolve(9);await Promise.resolve();
  expect(invoke).toHaveBeenLastCalledWith('local_interaction_unsubscribe',{id:'old',token:9});
 });
 it('reports a protocol mismatch without starting periodic reads',async()=>{
  vi.useFakeTimers();const invoke=vi.fn().mockRejectedValue('Command local_interaction_subscribe not found');setup(invoke);const fail=vi.fn();
  const stop=followInteraction('mission',vi.fn(),fail);await vi.advanceTimersByTimeAsync(60000);
  expect(invoke).toHaveBeenCalledTimes(1);expect(fail).toHaveBeenCalledOnce();stop();
 });
 it('surfaces subscription failures without silently starting a polling loop',async()=>{
  vi.useFakeTimers();const invoke=vi.fn().mockRejectedValue('permission denied');setup(invoke);const fail=vi.fn();
  const stop=followInteraction('mission',vi.fn(),fail);await vi.advanceTimersByTimeAsync(60000);
  expect(invoke).toHaveBeenCalledTimes(1);expect(fail).toHaveBeenCalledWith('permission denied');stop();
 });
});
