import {afterEach,expect,it,vi} from 'vitest';
import {cleanup,fireEvent,render,screen,waitFor} from '@solidjs/testing-library';
import {QueuedMessages} from '../src/QueuedMessages';
const queue=vi.hoisted(()=>({rows:[] as any[],retry:vi.fn(),send:vi.fn(),prioritize:vi.fn(),remove:vi.fn()}));
vi.mock('../src/localMessageQueue',()=>({
 queuedLocalMessages:()=>queue.rows,
 retryQueuedMessage:queue.retry,sendQueuedNow:queue.send,
 prioritizeQueuedMessage:queue.prioritize,removeQueuedMessage:queue.remove,canDiscardQueuedMessage:()=>true,
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

it('shows one line per message with edit, send next and remove actions, and marks the edited row',async()=>{
 queue.rows=['message 1','message 2','message 3'].map((text,i)=>({id:`m${i+1}`,text,state:'queued',waiting:true}));
 const edit=vi.fn();
 const ui=render(()=><QueuedMessages mission="local" onEdit={edit}/>);
 expect(ui.getByText('3 Queued')).toBeTruthy();
 expect(ui.getByText('to Send')).toBeTruthy();
 expect(screen.queryByRole('button',{name:'Send next: message 1'})).toBeNull();
 await fireEvent.click(screen.getByRole('button',{name:'Send next: message 3'}));
 expect(queue.prioritize).toHaveBeenCalledWith('m3');
 await waitFor(()=>expect((screen.getByRole('button',{name:'Remove queued message: message 2'}) as HTMLButtonElement).disabled).toBe(false));
 await fireEvent.click(screen.getByRole('button',{name:'Remove queued message: message 2'}));
 expect(queue.remove).toHaveBeenCalledWith('m2');
 await fireEvent.click(screen.getByRole('button',{name:'Edit queued message: message 2'}));
 expect(edit).toHaveBeenCalledWith({id:'m2',text:'message 2'});
 cleanup();
 render(()=><QueuedMessages mission="local" editing="m2" onEdit={edit}/>);
 expect(screen.getByText('Editing')).toBeTruthy();
 expect(screen.queryByText('to Send')).toBeNull();
 expect((screen.getByRole('button',{name:'Send now'}) as HTMLButtonElement).disabled).toBe(true);
 await fireEvent.click(screen.getByRole('button',{name:'Hide queued messages'}));
 expect(screen.queryByText('message 1')).toBeNull();
});
