import {afterEach, expect, it, vi} from 'vitest';
import * as api from '../src/api';
import * as clients from '../src/clientRuns';
import {copyTransfer, transferFiles, type TransferAction} from '../src/machineTransfer';
afterEach(()=>{vi.restoreAllMocks();vi.useRealTimers();});
it('copies a large conversation from Core and local files through the native adapter', async()=>{
  const action:TransferAction={id:'transfer',mission_id:'mission',phase:'copying',source:{kind:'client',id:'computer'},destination:{kind:'node',id:'old-agent'},backend:'codex',created_at:'',manifest:{bytes:1048584,excluded:[],files:[
    {path:'work.txt',bytes:3,sha256:'local',executable:false},
    {path:'.paloma/transfers/transfer/conversation.txt',bytes:1048581,sha256:'archive',executable:false},
  ]}};
  const invoke=vi.fn().mockResolvedValue({data:'local'});
  vi.spyOn(clients,'machineIdentity').mockResolvedValue('computer');
  vi.spyOn(clients,'nativeInvoke').mockReturnValue(invoke);
  const requests:Record<string,any>[]=[];
  vi.spyOn(api,'api').mockImplementation(async(_path,init)=>{
    const body=JSON.parse(init!.body as string);requests.push(body);
    if(body.operation.op==='stage')return {sealed:false,received:{}} as any;
    return {data:'archive'} as any;
  });
  await copyTransfer(action,()=>{});
  expect(invoke).toHaveBeenCalledTimes(1);
  expect(invoke.mock.calls[0][1].operation.path).toBe('work.txt');
  const reads=requests.filter(r=>r.side==='source');
  expect(reads.map(r=>r.operation.offset)).toEqual([0,1048576]);
  expect(reads.every(r=>r.operation.path===action.manifest!.files[1].path)).toBe(true);
  expect(requests.filter(r=>r.operation.op==='write')).toHaveLength(3);
});

it('retries interrupted checkpoint requests with a fresh deadline', async()=>{
  vi.useFakeTimers();
  const action={id:'transfer',mission_id:'mission',source:{kind:'core'},destination:{kind:'node',id:'old-agent'}} as TransferAction;
  const request=vi.spyOn(api,'api').mockImplementationOnce(async(_path,init)=>new Promise((_resolve,reject)=>init!.signal!.addEventListener('abort',()=>reject(new DOMException('Aborted','AbortError'))))).mockResolvedValue({data:'recovered'});
  const result=transferFiles(action,'source',{op:'read',path:'work.txt',offset:0});
  await vi.advanceTimersByTimeAsync(119999);
  expect(request).toHaveBeenCalledTimes(1);
  await vi.advanceTimersByTimeAsync(501);
  await expect(result).resolves.toEqual({data:'recovered'});
  expect(request).toHaveBeenCalledTimes(2);
  expect(request.mock.calls[0][1]?.signal).toBeInstanceOf(AbortSignal);
  expect(request.mock.calls[1][1]?.signal).not.toBe(request.mock.calls[0][1]?.signal);
  expect(request.mock.calls[0][1]?.body).toBe(request.mock.calls[1][1]?.body);
});
it('surfaces permanent refusals and bounds repeated network failures', async()=>{
  const action={id:'transfer',mission_id:'mission',source:{kind:'core'},destination:{kind:'node',id:'old-agent'}} as TransferAction;
  const request=vi.spyOn(api,'api').mockRejectedValue(new api.ApiError(409,'Source changed'));
  await expect(transferFiles(action,'source',{op:'read',path:'work.txt',offset:0})).rejects.toThrow('Source changed');
  expect(request).toHaveBeenCalledTimes(1);
  vi.useFakeTimers();request.mockClear().mockRejectedValue(new TypeError('Network unavailable'));
  const result=expect(transferFiles(action,'source',{op:'read',path:'work.txt',offset:0})).rejects.toThrow('Network unavailable');
  await vi.runAllTimersAsync();await result;
  expect(request).toHaveBeenCalledTimes(3);
});
