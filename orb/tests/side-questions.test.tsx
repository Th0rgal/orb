import { cleanup, fireEvent, render, screen, waitFor } from '@solidjs/testing-library';
import { afterEach, expect, it, vi } from 'vitest';
import { createSignal } from 'solid-js';
import { Composer } from '../src/App';
import { SideQuestions, type SideQuestionsHandle } from '../src/SideQuestionPanel';
import { askSide, boundedHistory, sideContext } from '../src/sideQuestionClient';
vi.mock('../src/btwAgent',async()=>{const client=await import('../src/sideQuestionClient');return {askBtwAgent:client.askSide,btwSession:()=>undefined,btwActivities:()=>[],btwItems:()=>[],btwThoughts:()=>thoughts.value,stopBtw:async()=>{},watchBtw:async()=>{}};});
const thoughts=vi.hoisted(()=>({value:[] as {kind:'think';key:string;text:string;done:boolean}[]}));
const storage=vi.hoisted(()=>new Map<string,unknown>());
vi.mock('../src/composerDrafts',()=>({
 readComposerDraft:async(key:string)=>storage.get('draft:'+key),
 saveComposerDraft:async(key:string,value:unknown)=>{storage.set('draft:'+key,structuredClone(value));},
 readSideThread:async(key:string)=>storage.get('thread:'+key),
 saveSideThread:async(key:string,value:unknown)=>{storage.set('thread:'+key,structuredClone(value));},
}));
afterEach(()=>{cleanup();vi.unstubAllGlobals();storage.clear();thoughts.value=[];});
it('routes /btw away from the working agent while it is busy',async()=>{
 const send=vi.fn(),ask=vi.fn(()=>true),stop=vi.fn();
 render(()=><Composer placeholder="Follow-up" busy onSend={send} onStop={stop} onBtw={ask}/>);
 fireEvent.input(screen.getByPlaceholderText('Follow-up'),{target:{value:'/btw What is left?'}});
 expect(screen.getByRole('status',{name:'Side question mode'})).toBeTruthy();
 fireEvent.click(screen.getByTitle('Ask side question'));
 await waitFor(()=>expect(ask).toHaveBeenCalledWith('What is left?',[],[]));expect(send).not.toHaveBeenCalled();expect(stop).not.toHaveBeenCalled();
 expect((screen.getByPlaceholderText('Follow-up') as HTMLTextAreaElement).value).toBe('');
});
it('keeps the question when another side question is pending',async()=>{
 render(()=><Composer placeholder="Follow-up" busy onSend={vi.fn()} onStop={()=>{}} onBtw={()=>false}/>);
 fireEvent.input(screen.getByPlaceholderText('Follow-up'),{target:{value:'/btw Why?'}});
 fireEvent.click(screen.getByTitle('Ask side question'));
 await waitFor(()=>expect((screen.getByPlaceholderText('Ask without interrupting…') as HTMLTextAreaElement).value).toBe('Why?'));
});
it('excludes private thinking, queued messages and unfinished replies from the snapshot',()=>{
 expect(sideContext([{kind:'think',key:'a',text:'secret',done:true},{kind:'user',key:'b',text:'queued',queued:true},{kind:'text',key:'c',text:'unfinished',live:true},{kind:'text',key:'d',text:'Finished build',live:false}])).toBe('Agent: Finished build');
 const text=sideContext([{kind:'text',key:'z',text:'é'.repeat(100000),live:false}]);expect(new TextEncoder().encode(text).length).toBeLessThanOrEqual(80000);
 expect(boundedHistory(Array.from({length:25},()=>({question:'Q',answer:'x'.repeat(10000)}))).length).toBe(6);
});
function response(events:unknown[]) {return new Response(new ReadableStream({start(controller){for(const event of events){const bytes=new TextEncoder().encode(`event: btw\r\ndata: ${JSON.stringify(event)}\r\n\r\n`);for(const byte of bytes)controller.enqueue(new Uint8Array([byte]));}controller.close();}}));}
it('decodes split UTF-8/SSE chunks and requires a terminal receipt',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>response([{type:'delta',text:'réussi'},{type:'done',answer:'réussi'}])));
 const receive=vi.fn();await askSide('mission','Question','snapshot',[],new AbortController().signal,receive);
 expect(receive).toHaveBeenCalledWith({type:'done',answer:'réussi'});
 vi.stubGlobal('fetch',vi.fn(async()=>response([{type:'delta',text:'partial'}])));
 await expect(askSide('mission','Question','snapshot',[],new AbortController().signal,receive)).rejects.toThrow('interrupted');
});
it('keeps the side answer separate and transfers only through an explicit draft action',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>response([{type:'start',model:'Assistant'},{type:'done',answer:'The build passed.'}])));
 const transfer=vi.fn();let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="side-test" items={[]} ref={h=>handle=h} onTransfer={transfer}/>);
 handle.ask('Status?');await screen.findByText('The build passed.');
 expect(transfer).not.toHaveBeenCalled();fireEvent.click(screen.getByText('Use in agent draft ↗'));
 expect(transfer).toHaveBeenCalledWith(expect.stringContaining('The build passed.'));
});
it('discards a late response when the selected mission changes',async()=>{
 let finish!:(r:Response)=>void;vi.stubGlobal('fetch',vi.fn(()=>new Promise<Response>(resolve=>finish=resolve)));
 const [mission,setMission]=createSignal('first');let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission={mission()} items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('First question');setMission('second');finish(response([{type:'done',answer:'Wrong mission answer'}]));
 await new Promise(resolve=>setTimeout(resolve,20));handle.open();
 expect(screen.queryByText('Wrong mission answer')).toBeNull();
});
it('restores an interrupted answer after remount without sending it again',async()=>{
 const fetch=vi.fn(async()=>new Response(new ReadableStream({start(controller){controller.enqueue(new TextEncoder().encode('event: btw\ndata: {"type":"delta","text":"Partial result"}\n\n'));}})));
 vi.stubGlobal('fetch',fetch);
 let handle!:SideQuestionsHandle;
 const mount=()=>render(()=><SideQuestions mission="interrupted-persistence" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 mount();await handle.ask('Pending question');await screen.findByText('Partial result');cleanup();
 mount();await screen.findByText(/Side question interrupted/);
 expect(screen.getByText('Partial result')).toBeTruthy();
 expect(fetch).toHaveBeenCalledTimes(1);
 expect(screen.getByRole('button',{name:'Retry'})).toBeTruthy();
});

it('edits a side question and resends only to the side lane',async()=>{
 const fetch=vi.fn(async()=>response([{type:'done',answer:'Side answer'}]));
 vi.stubGlobal('fetch',fetch);
 let handle!:SideQuestionsHandle;
 const transfer=vi.fn();
 render(()=><SideQuestions mission="edit-side" items={[]} ref={h=>handle=h} onTransfer={transfer}/>);
 await handle.ask('Original question');await screen.findByText('Side answer');
 fireEvent.dblClick(screen.getByText('Original question'));
 const editor=screen.getByLabelText('Edit prompt text');
 fireEvent.input(editor,{target:{value:'Revised question'}});
 fireEvent.keyDown(editor,{key:'Enter',ctrlKey:true});
 await waitFor(()=>expect(fetch).toHaveBeenCalledTimes(2));
 const [url,init]=fetch.mock.calls[1] as unknown as [string,RequestInit];
 expect(url).toContain('/edit-side/btw');
 expect(JSON.parse(init.body as string).question).toBe('Revised question');
 expect(transfer).not.toHaveBeenCalled();
});
it('offers @conversation in a side composer without a project',async()=>{
 render(()=><Composer sideQuestion picker={false} placeholder="Side draft" busy={false} onSend={()=>true} onStop={()=>{}}/>);
 const input=screen.getByPlaceholderText('Side draft') as HTMLTextAreaElement;
 fireEvent.input(input,{target:{value:'@',selectionStart:1}});
 fireEvent.click(await screen.findByRole('option',{name:'conversation · Latest agent conversation'}));
 expect(input.value).toBe('@conversation ');
});
it('labels the live snapshot while excluding thinking and queued drafts',()=>{
 expect(sideContext([{kind:'think',key:'a',text:'private',done:true},{kind:'user',key:'b',text:'unsent',queued:true},{kind:'text',key:'c',text:'Current progress',live:true}],true)).toBe('Agent (in progress at send time): Current progress');
});

it('queues a side question asked while the agent answers, then sends it',async()=>{
 const finish:((r:Response)=>void)[]=[];const fetched=vi.fn(()=>new Promise<Response>(resolve=>finish.push(resolve)));
 vi.stubGlobal('fetch',fetched);let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="queue-test" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 expect(await handle.ask('First question')).toBe(true);
 await waitFor(()=>expect(fetched).toHaveBeenCalledTimes(1));
 // Accepted, not refused: the draft is cleared and the question waits.
 expect(await handle.ask('Second question')).toBe(true);
 expect(await handle.ask('Third question')).toBe(true);
 const queued=await screen.findByLabelText('Queued side questions');
 expect(queued.textContent).toContain('2 Queued');expect(queued.textContent).toContain('Second question');
 expect(fetched).toHaveBeenCalledTimes(1);
 fireEvent.click(screen.getByLabelText('Remove queued side question: Third question'));
 finish[0](response([{type:'done',answer:'First answer'}]));
 await screen.findByText('First answer');
 await waitFor(()=>expect(fetched).toHaveBeenCalledTimes(2));
 expect(screen.queryByLabelText('Queued side questions')).toBeNull();
 finish[1](response([{type:'done',answer:'Second answer'}]));
 await screen.findByText('Second answer');
 expect(fetched).toHaveBeenCalledTimes(2);
});
it('keeps queued questions when the answer in progress fails',async()=>{
 const finish:((r:Response)=>void)[]=[];const fetched=vi.fn(()=>new Promise<Response>(resolve=>finish.push(resolve)));
 vi.stubGlobal('fetch',fetched);let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="queue-error-test" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('First question');await waitFor(()=>expect(fetched).toHaveBeenCalledTimes(1));
 await handle.ask('Second question');
 finish[0](response([{type:'delta',text:'partial'}]));
 await screen.findByRole('alert');
 expect(fetched).toHaveBeenCalledTimes(1);
 expect((await screen.findByLabelText('Queued side questions')).textContent).toContain('Second question');
});
it('shows the thoughts of the side agent while it answers',async()=>{
 thoughts.value=[{kind:'think',key:'t1',text:'Reading the ledger first.',done:false}];
 vi.stubGlobal('fetch',vi.fn(()=>new Promise<Response>(()=>{})));let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="thought-test" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('Status?');
 expect(await screen.findByText('Reading the ledger first.')).toBeTruthy();
});
