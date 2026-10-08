import { cleanup, fireEvent, render, screen, waitFor } from '@solidjs/testing-library';
import { afterEach, expect, it, vi } from 'vitest';
import { createSignal } from 'solid-js';
import { Composer } from '../src/App';
import { SideQuestions, type SideQuestionsHandle } from '../src/SideQuestionPanel';
import { askSide, boundedHistory, sideContext } from '../src/sideQuestionClient';
const serverReconcile=vi.hoisted(()=>({fn:async(_parent:string,local:any[])=>({history:local})}));
vi.mock('../src/btwAgent',async()=>{const client=await import('../src/sideQuestionClient');return {askBtwAgent:client.askSide,btwSession:()=>undefined,btwActivities:()=>[],btwItems:()=>[],btwThoughts:()=>thoughts.value,stopBtw:async()=>{},watchBtw:async()=>{},reconcileBtwServerHistory:(parent:string,local:any[])=>serverReconcile.fn(parent,local),isSyntheticRemoteAssistantNote:(text:string)=>/^Remote (?:node '[^']+'|\w+) job [0-9a-f-]{36} /.test(text)};});
const thoughts=vi.hoisted(()=>({value:[] as {kind:'think';key:string;text:string;done:boolean}[]}));
const storage=vi.hoisted(()=>new Map<string,unknown>());
vi.mock('../src/composerDrafts',()=>({
 readComposerDraft:async(key:string)=>storage.get('draft:'+key),
 saveComposerDraft:async(key:string,value:unknown)=>{storage.set('draft:'+key,structuredClone(value));},
 readSideThread:async(key:string)=>storage.get('thread:'+key),
 saveSideThread:async(key:string,value:unknown)=>{storage.set('thread:'+key,structuredClone(value));},
}));
afterEach(()=>{cleanup();vi.unstubAllGlobals();storage.clear();thoughts.value=[];serverReconcile.fn=async(_parent:string,local:any[])=>({history:local});});
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
it('keeps the same side-turn DOM node while streaming and committing the answer',async()=>{
 let controller!:ReadableStreamDefaultController<Uint8Array>;
 vi.stubGlobal('fetch',vi.fn(async()=>new Response(new ReadableStream({start(c){controller=c;}}))));
 let handle!:SideQuestionsHandle;
 const view=render(()=><SideQuestions mission="stable-turn" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('A stable question');
 const first=view.container.querySelector('[data-side-turn]');expect(first).toBeTruthy();
 const emit=(event:unknown)=>controller.enqueue(new TextEncoder().encode(`event: btw\ndata: ${JSON.stringify(event)}\n\n`));
 emit({type:'delta',text:'Partial'});await screen.findByText('Partial');
 expect(view.container.querySelector('[data-side-turn]')).toBe(first);
 emit({type:'done',answer:'Finished'});controller.close();await screen.findByText('Finished');
 expect(view.container.querySelector('[data-side-turn]')).toBe(first);
 expect(screen.getAllByText('A stable question')).toHaveLength(1);
 expect(screen.queryByText('Side agent is working…')).toBeNull();
});

it('shows the remote capacity wait while a side question is pending',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>new Response(new ReadableStream({start(controller){
  controller.enqueue(new TextEncoder().encode('event: btw\ndata: {"type":"start","model":"opencode · builtin/smart"}\n\nevent: btw\ndata: {"type":"status","text":"Waiting for capacity on old-agent…"}\n\n'));
 }}))));
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="capacity-wait" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('Inspect the running mission');
 await waitFor(()=>expect(screen.getByText('Waiting for capacity on old-agent…')).toBeTruthy());
 expect(screen.getByPlaceholderText('Queue a side question…')).toBeTruthy();
});

it('offers a reconnect path for a live side session after its local attempt is lost',async()=>{
 const id='12345678-1234-1234-1234-123456789abc';
 vi.stubGlobal('fetch',vi.fn(async()=>response([{type:'error',message:`A side agent is already queued or running for this conversation (${id}). Reconnect to or stop that side session before starting another; this question was not sent.`}])));
 const open=vi.fn();let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="lost-attempt" items={[]} ref={h=>handle=h} onTransfer={()=>{}} onOpenSession={open}/>);
 await handle.ask('Unsent question');
 fireEvent.click(await screen.findByText('Open existing side agent'));
 expect(open).toHaveBeenCalledWith(id);
 expect(screen.getText ? screen.getByText('Unsent question') : screen.getByText('Unsent question')).toBeTruthy();
});

it('strips synthetic remote cancellation notes from saved side history on mount',async()=>{
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 await writeSideQuestion(sideQuestionKey('synthetic-history'),{
  history:[{id:'t1',question:'Analyze status',answer:"Remote node 'old-agent' job e7c48aba-3101-4c3b-b7ad-1e17dab704dd reached state 'cancelled' (exit None) after the mission left Active (paused); the mission status is preserved. error: cancelled"}],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:false,
 });
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="synthetic-history" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 expect(await screen.findByText(/Side question was interrupted before the agent answered/)).toBeTruthy();
 expect(screen.queryByText(/reached state 'cancelled'/)).toBeNull();
 expect(screen.getByText('Analyze status')).toBeTruthy();
});

it('restores missing server /btw turns and clears stale interrupted notice when reopening a mission',async()=>{
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 await writeSideQuestion(sideQuestionKey('d04c77b2-7028-4c03-b7c1-ab20b818e0f3'),{
  history:[],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{question:'what’s the status? What’s left to do?',answer:'',error:'Side question interrupted. Retry to request a complete answer.'},
 });
 serverReconcile.fn=async()=>({
  history:[
   {id:'s1',question:'Où en es-tu ? Tu travailles sur quoi ?',answer:'Validation en cours sur Slice 1.'},
   {id:'s2',question:'what’s the status? What’s left to do?',answer:'Slices 1-3 pushed; Slice 4 validating.'},
  ],
 });
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="d04c77b2-7028-4c03-b7c1-ab20b818e0f3" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 expect(await screen.findByText('Validation en cours sur Slice 1.')).toBeTruthy();
 expect(await screen.findByText('Slices 1-3 pushed; Slice 4 validating.')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
});

it('clears the preparing state after sending a question from the side panel composer',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>response([{type:'done',answer:'Side composer reply'}])));
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="composer-prepare-reset" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 handle.open();
 const input=await screen.findByPlaceholderText('Ask a side question…');
 fireEvent.input(input,{target:{value:'From side composer'}});
 fireEvent.keyDown(input,{key:'Enter'});
 expect(await screen.findByText('Side composer reply')).toBeTruthy();
 expect(screen.queryByText('Sending…')).toBeNull();
 expect(screen.queryByText('Side agent is working…')).toBeNull();
});

it('allows dismissing a failed side question turn',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>response([{type:'error',message:'Temporary failure'}])));
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="dismiss-error-test" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('Broken question');
 expect(await screen.findByText(/Temporary failure/)).toBeTruthy();
 fireEvent.click(screen.getByRole('button',{name:'Dismiss'}));
 await waitFor(()=>expect(screen.queryByText(/Temporary failure/)).toBeNull());
 expect(screen.queryByText('Broken question')).toBeNull();
});



