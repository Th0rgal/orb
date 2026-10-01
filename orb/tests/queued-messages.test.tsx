import {afterEach,expect,it,vi} from 'vitest';
import {cleanup,fireEvent,render,screen,waitFor} from '@solidjs/testing-library';
import {QueuedMessages} from '../src/QueuedMessages';
const queue=vi.hoisted(()=>({rows:[] as any[],retry:vi.fn(),send:vi.fn()}));
vi.mock('../src/localMessageQueue',()=>({
 queuedLocalMessages:()=>queue.rows,
 retryQueuedMessage:queue.retry,sendQueuedNow:queue.send,
 takeQueuedMessage:vi.fn(),removeQueuedMessage:vi.fn(),canDiscardQueuedMessage:()=>true,
}));
afterEach(()=>{cleanup();queue.rows=[];vi.resetAllMocks();});
it('offers Retry without a disabled Send now for an interrupted message',async()=>{
 queue.rows=[{id:'interrupted',text:'vas-y',state:'accepted',interrupted:true,error:'Previous agent may still be running.'}];
 let finish!:()=>void;queue.retry.mockImplementation(()=>new Promise<void>(resolve=>{finish=resolve;}));
 render(()=><QueuedMessages mission="local"/>);
 expect(screen.queryByRole('button',{name:'Send now'})).toBeNull();
 const retry=screen.getByRole('button',{name:'Retry'}) as HTMLButtonElement;
 await fireEvent.click(retry);
 expect(queue.retry).toHaveBeenCalledWith('interrupted');expect(retry.disabled).toBe(true);
 await fireEvent.click(retry);expect(queue.retry).toHaveBeenCalledTimes(1);
 finish();await waitFor(()=>expect(retry.disabled).toBe(false));
});
it('keeps Send now actionable for a queued message alongside an error',async()=>{
 queue.rows=[{id:'failed',text:'failed',state:'error',error:'Try again'}, {id:'queued',text:'next',state:'queued',waiting:true}];
 render(()=><QueuedMessages mission="local"/>);
 await fireEvent.click(screen.getByRole('button',{name:'Send now'}));
 expect(queue.send).toHaveBeenCalledWith('local');expect(queue.retry).not.toHaveBeenCalled();
});
