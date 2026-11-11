import { cleanup, fireEvent, render, screen, waitFor } from '@solidjs/testing-library';
import { afterEach, expect, it, vi } from 'vitest';
import { createSignal } from 'solid-js';
import { Composer } from '../src/composer/Composer';
import { SideQuestions, type SideQuestionsHandle } from '../src/SideQuestionPanel';
import { askSide, boundedHistory, sideContext } from '../src/sideQuestionClient';
import { resetSideQuestionStorageForTest } from '../src/sideQuestionStorage';
const serverReconcile=vi.hoisted(()=>({
 fn:async(_parent:string,local:any[],_signal?:AbortSignal,_options?:{force?:boolean})=>({history:local} as {history:any[];activeSession?:any;latest?:string;authoritative?:boolean}),
 reconnect:async(_parent:string,sideId:string)=>({id:sideId,question:'Running side question',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0}),
}));
const warmMock=vi.hoisted(()=>({
 current:new Map<string,{history:any[];activeSession?:any;latest?:string;clean:boolean}>(),
 updateSpy:vi.fn(),
}));
const watchMock=vi.hoisted(()=>({fn:async(_parent:string,_signal:AbortSignal,_receive:(e:any)=>void)=>{}}));
const askMock=vi.hoisted(()=>({fn:undefined as typeof askSide|undefined}));
const queueFollowUpMock=vi.hoisted(()=>({enabled:false,fn:vi.fn()}));
const launchMock=vi.hoisted(()=>({
 pending:undefined as Promise<void>|undefined,
 lastError:undefined as {error:string;notSent:boolean}|undefined,
}));
const sessionMock=vi.hoisted(()=>({current:undefined as any,rev:undefined as (()=>number)|undefined,bump:undefined as (()=>void)|undefined}));
vi.mock('../src/btwAgent',async()=>{const {createSignal}=await import('solid-js');const [rev,setRev]=createSignal(0);sessionMock.rev=rev;sessionMock.bump=()=>setRev(v=>v+1);const client=await import('../src/sideQuestionClient');return {askBtwAgent:(...args:Parameters<typeof client.askSide>)=>(askMock.fn??client.askSide)(...args),btwSession:()=>{sessionMock.rev?.();return sessionMock.current;},clearStaleBtwSessionActive:()=>{if(sessionMock.current?.active){sessionMock.current={...sessionMock.current,active:false,startedAt:undefined};sessionMock.bump?.();}},noteBtwPanelOpen:()=>()=>{},btwLaunchPending:()=>launchMock.pending,btwLastLaunchError:()=>launchMock.lastError,startFreshBtwSession:()=>{if(sessionMock.current){sessionMock.current={...sessionMock.current,freshSession:true};sessionMock.bump?.();}},btwActivities:()=>[],btwItems:()=>[],btwThoughts:()=>thoughts.value,stopBtw:async()=>{},watchBtw:(parent:string,signal:AbortSignal,receive:(e:any)=>void)=>watchMock.fn(parent,signal,receive),reconnectBtwSession:(parent:string,sideId:string)=>serverReconcile.reconnect(parent,sideId),reconcileBtwServerHistory:(parent:string,local:any[],signal?:AbortSignal,options?:{force?:boolean})=>serverReconcile.fn(parent,local,signal,options),peekWarmBtwState:(parent:string)=>warmMock.current.get(parent),updateWarmBtwHistory:(...args:any[])=>warmMock.updateSpy(...args),get queueBtwFollowUp(){return queueFollowUpMock.enabled?queueFollowUpMock.fn:undefined;},isSyntheticRemoteAssistantNote:(text:string)=>/^Remote (?:node '[^']+'|\w+) job [0-9a-f-]{36} /.test(text)};});
const thoughts=vi.hoisted(()=>({value:[] as {kind:'think';key:string;text:string;done:boolean}[]}));
const storage=vi.hoisted(()=>new Map<string,unknown>());
vi.mock('../src/composerDrafts',()=>({
 readComposerDraft:async(key:string)=>storage.get('draft:'+key),
 saveComposerDraft:async(key:string,value:unknown)=>{storage.set('draft:'+key,structuredClone(value));},
 readSideThread:async(key:string)=>storage.get('thread:'+key),
 saveSideThread:async(key:string,value:unknown)=>{storage.set('thread:'+key,structuredClone(value));},
}));
afterEach(()=>{cleanup();vi.unstubAllGlobals();storage.clear();resetSideQuestionStorageForTest();thoughts.value=[];sessionMock.current=undefined;askMock.fn=undefined;launchMock.pending=undefined;launchMock.lastError=undefined;warmMock.current.clear();warmMock.updateSpy.mockReset();queueFollowUpMock.enabled=false;queueFollowUpMock.fn.mockReset();watchMock.fn=async()=>{};serverReconcile.fn=async(_parent:string,local:any[])=>({history:local});serverReconcile.reconnect=async(_parent:string,sideId:string)=>({id:sideId,question:'Running side question',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0});});
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
 expect(screen.getByText('Unsent question')).toBeTruthy();
});

it('reconnects an existing side session inside /btw without forking into the sidebar when onOpenSession is omitted',async()=>{
 const id='23af9c91-5304-4679-ae0f-90671af270c9';
 vi.stubGlobal('fetch',vi.fn(async()=>response([{type:'error',message:`A side agent is already queued or running for this conversation (${id}). Reconnect to or stop that side session before starting another; this question was not sent.`}])));
 const reconnectSpy=vi.fn(async(_parent:string,sideId:string)=>({id:sideId,question:'Earlier question',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0}));
 serverReconcile.reconnect=reconnectSpy;
 serverReconcile.fn=async()=>({history:[{id:'turn-1',question:'Earlier question',answer:'Side synthesis ready.'}],latest:id});
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="0c532a32-2fb5-4fd6-ba6b-b9820d12c097" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('Follow-up side question');
 fireEvent.click(await screen.findByText('Open existing side agent'));
 await waitFor(()=>expect(reconnectSpy).toHaveBeenCalledWith('0c532a32-2fb5-4fd6-ba6b-b9820d12c097',id));
 expect(await screen.findByText('Side synthesis ready.')).toBeTruthy();
 const input=screen.getByPlaceholderText('Ask a side question…') as HTMLTextAreaElement;
 await waitFor(()=>expect(input.value).toBe('Follow-up side question'));
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



it('keeps a question that was not sent as a pending bubble whose Retry resends it',async()=>{
 const notSent=Object.assign(new Error('Connection interrupted — your question was not sent. Retry to send it.'),{notSent:true});
 const fetch=vi.fn().mockRejectedValueOnce(notSent).mockResolvedValue(response([{type:'done',answer:'Sent at last.'}]));
 vi.stubGlobal('fetch',fetch);let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="not-sent" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('Via tailscale?');
 await screen.findByText('Question not sent');
 expect(screen.getByText('Via tailscale?')).toBeTruthy();
 fireEvent.click(screen.getByText('Retry'));
 await screen.findByText('Sent at last.');
 expect(fetch).toHaveBeenCalledTimes(2);
 expect(screen.queryByText('Question not sent')).toBeNull();
});

it('reconnects to an active server /btw run on remount without flashing Side question interrupted',async()=>{
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 await writeSideQuestion(sideQuestionKey('0c532a32-2fb5-4fd6-ba6b-b9820d12c097'),{
  history:[],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{question:'Analyze editablePaths trap and turbo-lean usage',answer:'',error:''},
 });
 let finishReconcile!:(res:{history:any[];activeSession?:any;latest?:string})=>void;
 serverReconcile.fn=()=>new Promise(resolve=>{finishReconcile=resolve;});
 let finishWatch!:(answer:string)=>void;
 watchMock.fn=(_parent,_signal,receive)=>new Promise<void>(resolve=>{
  receive({type:'start',model:'opencode · builtin/smart'});
  finishWatch=answer=>{receive({type:'done',answer});resolve();};
 });
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="0c532a32-2fb5-4fd6-ba6b-b9820d12c097" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 expect(await screen.findByText('Reconnecting…')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
 finishReconcile({
  history:[],
  activeSession:{id:'634505a6-4371-4fa1-91c2-7bbcc62bdb6f',question:'Analyze editablePaths trap and turbo-lean usage',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0},
  latest:'634505a6-4371-4fa1-91c2-7bbcc62bdb6f',
 });
 expect(await screen.findByText('Starting side agent…')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
 serverReconcile.fn=async()=>({
  history:[{id:'s1',question:'Analyze editablePaths trap and turbo-lean usage',answer:'Complete consensus prompt ready.'}],
  latest:'634505a6-4371-4fa1-91c2-7bbcc62bdb6f',
 });
 finishWatch('Complete consensus prompt ready.');
 expect(await screen.findByText('Complete consensus prompt ready.')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
});

it('clears a previously persisted Side question interrupted banner when Core reports the side session is still active',async()=>{
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 await writeSideQuestion(sideQuestionKey('stale-error-active'),{
  history:[],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{question:'Analyze editablePaths',answer:'',error:'Side question interrupted. Retry to request a complete answer.'},
 });
 serverReconcile.fn=async()=>({
  history:[],
  activeSession:{id:'634505a6-live',question:'Analyze editablePaths',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0},
  latest:'634505a6-live',
 });
 watchMock.fn=(_parent,_signal,receive)=>new Promise<void>(()=>{
  receive({type:'start',model:'opencode · builtin/smart'});
 });
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="stale-error-active" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 expect(await screen.findByText('Starting side agent…')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
});

it('submits /btw follow-ups into Core RemoteQueue in advance while busy and keeps Working… visible during partial streaming',async()=>{
 queueFollowUpMock.enabled=true;
 queueFollowUpMock.fn.mockImplementation(async(_parent:string,question:string,_ctx:string,_history:any[],_attachments:any[],clientId:string)=>({
  id:clientId,
  missionId:'side-live-1',
  prompt:`You are the independent /btw agent sharing the main agent's working folder.\n\n<main_conversation_update>\nctx\n</main_conversation_update>\n\nCurrent request:\n${question}\n`,
  queued:true,
  local:false,
 }));
 let controller!:ReadableStreamDefaultController<Uint8Array>;
 vi.stubGlobal('fetch',vi.fn(async(url:string)=>{
  if(String(url).includes('/api/control/queue'))return Response.json([]);
  return new Response(new ReadableStream({start(c){controller=c;}}));
 }));
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="unified-queue-test" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('First running question');
 controller.enqueue(new TextEncoder().encode('event: btw\ndata: {"type":"delta","text":"Streaming partial narration…"}\n\n'));
 expect(await screen.findByText('Streaming partial narration…')).toBeTruthy();
 // Live progress status stays visible even after partial text streams.
 expect(screen.getByText('Working…')).toBeTruthy();
 const sideInput=screen.getByPlaceholderText('Queue a side question…');
 fireEvent.input(sideInput,{target:{value:'Queued in advance'}});
 fireEvent.keyDown(sideInput,{key:'Enter'});
 await waitFor(()=>expect(queueFollowUpMock.fn).toHaveBeenCalledTimes(1));
 const queueRegion=await screen.findByLabelText('Queued messages');
 expect(queueRegion.textContent).toContain('1 Queued');
 expect(queueRegion.textContent).toContain('Queued in advance');
 expect(screen.getByRole('button',{name:'Send now: Queued in advance'})).toBeTruthy();
});

it('deduplicates already-answered legacy saved.queue items on mount and retains failed migrations until retry succeeds',async()=>{
 queueFollowUpMock.enabled=true;
 let failFirst=true;
 queueFollowUpMock.fn.mockImplementation(async(_parent:string,question:string,_ctx:string,_history:any[],_attachments:any[],clientId:string)=>{
  if(failFirst){failFirst=false;throw new Error('Transient network failure');}
  return {
   id:clientId,missionId:'side-live-2',prompt:`You are the independent /btw agent sharing the main agent's working folder.\n\nCurrent request:\n${question}\n`,queued:true,local:false,
  };
 });
 vi.stubGlobal('fetch',vi.fn(async()=>Response.json([])));
 const {sideQuestionKey,readSideQuestion,writeSideQuestion}=await import('../src/sideQuestionStorage');
 const storageId=sideQuestionKey('legacy-migrate');
 await writeSideQuestion(storageId,{
  history:[],draft:'',model:'opencode · builtin/smart',open:true,docked:true,
  queue:[
   {id:'9030da6e-f2d9-433a-99c2-e49de1322e23',question:'Already answered on server'},
   {id:'11111111-2222-4333-8444-555555555555',question:'Still needs to be sent'},
  ],
 });
 let streamNotify:((event:any)=>void)|undefined;
 const streamMod=await import('../src/stream');
 const spy=vi.spyOn(streamMod,'streamMission').mockImplementation((_id,cb)=>{streamNotify=cb as any;return ()=>{};});
 serverReconcile.fn=async()=>({
  history:[{id:'h1',question:'Already answered on server',answer:'Server Turn 5 reply.'}],
  activeSession:{id:'side-live-2',question:'Currently running',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0},
  latest:'side-live-2',
 });
 watchMock.fn=(_parent,_signal,receive)=>new Promise<void>(()=>{receive({type:'start',model:'opencode · builtin/smart'});});
 let handle!:SideQuestionsHandle;
 try{
  render(()=><SideQuestions mission="legacy-migrate" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
  await waitFor(()=>expect(queueFollowUpMock.fn).toHaveBeenCalledTimes(1));
  expect(queueFollowUpMock.fn.mock.calls[0][1]).toBe('Still needs to be sent');
  // Failed migration keeps the unsent legacy item persisted (while dropping the answered one).
  await waitFor(async()=>{
   const persisted=await readSideQuestion(storageId);
   expect(persisted?.queue?.map(q=>q.question)).toEqual(['Still needs to be sent']);
  });
  // Next reconcile retries the retained legacy item and clears it once acknowledged.
  streamNotify?.({type:'mission_status_changed'});
  await waitFor(()=>expect(queueFollowUpMock.fn).toHaveBeenCalledTimes(2));
  await waitFor(async()=>{
   const persisted=await readSideQuestion(storageId);
   expect(persisted?.queue).toEqual([]);
  });
 }finally{spy.mockRestore();}
});

it('handles live turn transitions when an immediately-admitted follow-up queues another turn',async()=>{
 queueFollowUpMock.enabled=true;
 queueFollowUpMock.fn
  .mockResolvedValueOnce({id:'turn-2-id',missionId:'side-race-1',prompt:'Wrapped\n\nCurrent request:\nSecond question\n',queued:false,local:false})
  .mockResolvedValueOnce({id:'turn-3-id',missionId:'side-race-1',prompt:'Wrapped\n\nCurrent request:\nThird question\n',queued:true,local:false});
 let emitWatch:((event:any)=>void)|undefined;
 watchMock.fn=(_parent,_signal,receive)=>new Promise<void>(resolve=>{
  emitWatch=(event:any)=>{receive(event);if(event.type==='done')resolve();};
  receive({type:'start',model:'opencode · builtin/smart'});
 });
 let controller!:ReadableStreamDefaultController<Uint8Array>;
 vi.stubGlobal('fetch',vi.fn(async(url:string)=>{
  if(String(url).includes('/api/control/queue'))return Response.json([]);
  return new Response(new ReadableStream({start(c){controller=c;}}));
 }));
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="admit-race-test" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('First question');
 controller.enqueue(new TextEncoder().encode('event: btw\ndata: {"type":"delta","text":"Working…"}\n\n'));
 // Submit second question while busy -> Core admits immediately (queued: false) because Turn 1 just ended:
 await handle.ask('Second question');
 await waitFor(()=>expect(emitWatch).toBeTypeOf('function'));
 // Queue third question while Turn 2 is running:
 await handle.ask('Third question');
 expect((await screen.findByLabelText('Queued messages')).textContent).toContain('Third question');
 // Core finishes Turn 2 and starts Turn 3:
 emitWatch!({type:'turn',question:'Third question',messageId:'turn-3-id',completed:{question:'Second question',answer:'Second turn answer.'}});
 expect(await screen.findByText('Second turn answer.')).toBeTruthy();
 await waitFor(()=>expect(screen.queryByLabelText('Queued messages')).toBeNull());
 emitWatch!({type:'done',answer:'Third turn answer.'});
 expect(await screen.findByText('Third turn answer.')).toBeTruthy();
});

it('lets the user arm a clean side session from the panel header',async()=>{
 sessionMock.current={id:'side-bloated',question:'Prior',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0};
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="fresh-btn-test" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 handle.open();
 const btn=await screen.findByRole('button',{name:'New side session'});
 expect((btn as HTMLButtonElement).disabled).toBe(false);
 expect(screen.getByPlaceholderText('Ask a side question…')).toBeTruthy();
 fireEvent.click(btn);
 expect(sessionMock.current.freshSession).toBe(true);
 expect((btn as HTMLButtonElement).disabled).toBe(true);
 expect(screen.getByPlaceholderText('Ask in a new side session…')).toBeTruthy();
});

it('anchors Working elapsed time on the turn start timestamp across page reloads and turn rollovers',async()=>{
 const twoMinFiveSecAgo=new Date(Date.now()-125_000).toISOString();
 sessionMock.current={id:'side-elapsed',question:'Long proof summary?',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0,startedAt:twoMinFiveSecAgo};
 let emitWatch:((event:any)=>void)|undefined;
 watchMock.fn=(_parent,_signal,receive)=>new Promise<void>(resolve=>{
  emitWatch=(event:any)=>{receive(event);if(event.type==='done')resolve();};
  receive({type:'start',model:'opencode · builtin/smart',startedAt:twoMinFiveSecAgo});
  receive({type:'status',text:'Working…'});
 });
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 await writeSideQuestion(sideQuestionKey('elapsed-reload-test'),{
  history:[],draft:'',model:'opencode · builtin/smart',open:true,docked:true,
 });
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="elapsed-reload-test" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await waitFor(()=>{
  const progress=document.querySelector('.btw-progress')?.textContent??'';
  expect(progress).toContain('Working… · 2 min');
 });
 // Rolling over to a newly dequeued turn resets the timer to the new turn's timestamp:
 const oneSecAgo=new Date(Date.now()-1_000).toISOString();
 emitWatch!({type:'turn',question:'Quick follow-up?',startedAt:oneSecAgo,completed:{question:'Long proof summary?',answer:'Summary complete.'}});
 emitWatch!({type:'status',text:'Working…'});
 await waitFor(()=>{
  const progress=document.querySelector('.btw-progress')?.textContent??'';
  expect(progress).toBe('Working…');
 });
});

it('replays 06203bdc: never overwrites a clean warm /btw completion with stale IndexedDB pending history',async()=>{
 const parentId='06203bdc-3543-483e-a8c5-3bf20eb5c34a';
 const sideId='1013a4da-ba7a-4628-91a7-0c859b78438c';
 const {sideQuestionKey,readSideQuestion,writeSideQuestion}=await import('../src/sideQuestionStorage');
 const staleTwelveTurns=Array.from({length:12},(_,i)=>({
  id:`prior-${i+1}`,
  question:`Earlier question ${i+1}`,
  answer:`Earlier answer ${i+1}`,
 }));
 const completedThirteenTurns=[
  ...staleTwelveTurns,
  {
   id:`${sideId}:10`,
   question:'nothing has been merged on main for 8h, why?',
   answer:'PR #1543 is waiting on the required CI check.',
   at:'2026-11-04T23:05:54Z',
   userEventId:'aae35757-783a-4754-b132-451ada03f287',
  },
 ];
 await writeSideQuestion(sideQuestionKey(parentId),{
  history:staleTwelveTurns,
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{
   question:'nothing has been merged on main for 8h, why?',
   answer:'',
   error:'',
   turnId:'aae35757-783a-4754-b132-451ada03f287',
   startedAt:'2026-11-04T23:04:25Z',
  },
 });
 // Background warm sync already reconciled Core and flipped session.active -> false:
 sessionMock.current={id:sideId,question:'nothing has been merged on main for 8h, why?',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0};
 warmMock.current.set(parentId,{history:completedThirteenTurns,latest:sideId,clean:true});
 serverReconcile.fn=async(parent)=>({
  history:warmMock.current.get(parent)?.history??[],
  latest:sideId,
  authoritative:true,
 });
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission={parentId} items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 expect(await screen.findByText('PR #1543 is waiting on the required CI check.')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
 expect(warmMock.updateSpy).not.toHaveBeenCalled();
 await waitFor(async()=>{
  const healed=await readSideQuestion(sideQuestionKey(parentId));
  expect(healed?.history).toHaveLength(13);
  expect(healed?.pending).toBeUndefined();
 });
});

it('auto-heals an already-persisted Side question interrupted state via forced Core reconcile without flashing the error',async()=>{
 const parentId='06203bdc-healed';
 const {sideQuestionKey,readSideQuestion,writeSideQuestion}=await import('../src/sideQuestionStorage');
 await writeSideQuestion(sideQuestionKey(parentId),{
  history:[{id:'p1',question:'Prior?',answer:'Prior answer.'}],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{
   question:'nothing has been merged on main for 8h, why?',
   answer:'',
   error:'Side question interrupted. Retry to request a complete answer.',
   turnId:'aae35757-783a-4754-b132-451ada03f287',
  },
 });
 let finishReconcile!:(res:{history:any[];latest?:string;authoritative?:boolean})=>void;
 const reconcileCalls:Array<{force?:boolean}|undefined>=[];
 serverReconcile.fn=(_parent,_local,_sig,options)=>{
  reconcileCalls.push(options);
  return new Promise(resolve=>{finishReconcile=resolve;});
 };
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission={parentId} items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 expect(await screen.findByText('Reconnecting…')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
 expect(reconcileCalls[0]).toEqual({force:true});
 finishReconcile({
  history:[
   {id:'p1',question:'Prior?',answer:'Prior answer.'},
   {id:'p2',question:'nothing has been merged on main for 8h, why?',answer:'Recovered authoritative Core answer.',userEventId:'aae35757-783a-4754-b132-451ada03f287'},
  ],
  latest:'1013a4da-ba7a-4628-91a7-0c859b78438c',
  authoritative:true,
 });
 expect(await screen.findByText('Recovered authoritative Core answer.')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
 await waitFor(async()=>{
  const healed=await readSideQuestion(sideQuestionKey(parentId));
  expect(healed?.pending).toBeUndefined();
 });
});

it('keeps awaitingServerPending in reconnecting state on non-authoritative reconcile and heals when connectivity returns',async()=>{
 const parentId='net-blip-btw';
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 await writeSideQuestion(sideQuestionKey(parentId),{
  history:[],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{question:'Check build logs',answer:'',error:''},
 });
 let streamReconnect:(()=>void)|undefined;
 const streamMod=await import('../src/stream');
 const spy=vi.spyOn(streamMod,'streamMission').mockImplementation((_id,_cb,onReconnect)=>{
  streamReconnect=onReconnect;
  return ()=>{};
 });
 let attempt=0;
 serverReconcile.fn=async()=>{
  attempt++;
  if(attempt===1)return {history:[],latest:'side-net-1',authoritative:false};
  return {
   history:[{id:'s1',question:'Check build logs',answer:'All green after reconnect.'}],
   latest:'side-net-1',
   authoritative:true,
  };
 };
 let handle!:SideQuestionsHandle;
 try{
  render(()=><SideQuestions mission={parentId} items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
  expect(await screen.findByText('Connection interrupted — reconnecting…')).toBeTruthy();
  expect(screen.queryByText(/Side question interrupted/)).toBeNull();
  streamReconnect?.();
  expect(await screen.findByText('All green after reconnect.')).toBeTruthy();
  expect(screen.queryByText(/Side question interrupted/)).toBeNull();
 }finally{
  spy.mockRestore();
 }
});

it('disambiguates duplicate question prompts ("and now?") and makes Retry adopt Core completion without resending',async()=>{
 const parentId='dup-and-retry';
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 await writeSideQuestion(sideQuestionKey(parentId),{
  history:[{id:'t1',question:'and now?',answer:'First status check.',at:'2026-11-04T19:21:00Z'}],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{question:'and now?',answer:'',error:'',startedAt:'2026-11-04T20:07:00Z'},
 });
 const fetchSpy=vi.fn(async()=>response([{type:'done',answer:'Should never be called'}]));
 vi.stubGlobal('fetch',fetchSpy);
 // Initial reconcile returns only the first "and now?" (second turn was interrupted before completing):
 serverReconcile.fn=async()=>({
  history:[{id:'t1',question:'and now?',answer:'First status check.',at:'2026-11-04T19:21:00Z'}],
  authoritative:true,
 });
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission={parentId} items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 // Must NOT falsely treat the first "and now?" as answering the second "and now?":
 expect(await screen.findByText(/Side question interrupted/)).toBeTruthy();
 expect(screen.getByText('First status check.')).toBeTruthy();

 // Core has now completed the second "and now?" before the user clicks Retry:
 serverReconcile.fn=async()=>({
  history:[
   {id:'t1',question:'and now?',answer:'First status check.',at:'2026-11-04T19:21:00Z'},
   {id:'t2',question:'and now?',answer:'Second status check complete.',at:'2026-11-04T20:07:30Z'},
  ],
  authoritative:true,
 });
 fireEvent.click(screen.getByRole('button',{name:'Retry'}));
 expect(await screen.findByText('Second status check complete.')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
 expect(fetchSpy).not.toHaveBeenCalled();
});

it('reconciles with Core when an unmounted btwLaunchPending settles to inactive, and preserves BtwNotSentError when launch never reached Core',async()=>{
 const {sideQuestionKey,readSideQuestion,writeSideQuestion}=await import('../src/sideQuestionStorage');
 // Case 1: launch settled and Core already completed the fast side turn while unmounted:
 const fastParent='fast-launch-settled';
 await writeSideQuestion(sideQuestionKey(fastParent),{
  history:[],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{question:'Fast status check?',answer:'',error:'',turnId:'fast-turn-1'},
 });
 let resolveLaunch!:()=>void;
 launchMock.pending=new Promise<void>(r=>{resolveLaunch=r;});
 let serverFinished=false;
 serverReconcile.fn=async()=>serverFinished
  ?{history:[{id:'f1',question:'Fast status check?',answer:'Fast answer from Core.',userEventId:'fast-turn-1'}],latest:'fast-side-1',authoritative:true}
  :{history:[],authoritative:true};
 let handle!:SideQuestionsHandle;
 const view1=render(()=><SideQuestions mission={fastParent} items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 expect(await screen.findByText('Starting side agent…')).toBeTruthy();

 // Launch finishes and background/Core already marked session inactive:
 sessionMock.current={id:'fast-side-1',question:'Fast status check?',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0};
 serverFinished=true;
 launchMock.pending=undefined;
 resolveLaunch();

 expect(await screen.findByText('Fast answer from Core.')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
 view1.unmount();

 // Case 2: launch failed pre-acceptance (BtwNotSentError) while unmounted:
 const notSentParent='launch-not-sent';
 await writeSideQuestion(sideQuestionKey(notSentParent),{
  history:[],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{question:'Offline question?',answer:'',error:'',turnId:'offline-turn-1'},
 });
 sessionMock.current=undefined;
 let resolveFailedLaunch!:()=>void;
 launchMock.pending=new Promise<void>(r=>{resolveFailedLaunch=r;});
 render(()=><SideQuestions mission={notSentParent} items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 expect(await screen.findByText('Starting side agent…')).toBeTruthy();

 launchMock.lastError={error:'Connection interrupted — your question was not sent. Retry to send it.',notSent:true};
 launchMock.pending=undefined;
 resolveFailedLaunch();

 expect(await screen.findByText('Question not sent')).toBeTruthy();
 expect(screen.getByText('Connection interrupted — your question was not sent. Retry to send it.')).toBeTruthy();
 expect(screen.queryByText(/Side question interrupted/)).toBeNull();
 await waitFor(async()=>{
  const saved=await readSideQuestion(sideQuestionKey(notSentParent));
  expect(saved?.pending?.notSent).toBe(true);
 });
});

it('replays 9409f9a9: renders completed /btw turn synchronously on frame 0 without flashing Starting side agent… even if localStorage still had active=true',async()=>{
 const parentId='9409f9a9-d3eb-416a-b5a8-978508bed734';
 const sideId='side-9409';
 const oneHourSeventeenMinAgo=new Date(Date.now()-4_620_000).toISOString();
 const {sideQuestionKey,readSideQuestion,writeSideQuestion}=await import('../src/sideQuestionStorage');
 const qText='I sent A as a steering. Regarding B and the remaining gaps and high-value tooling and patterns from ethlib, propose a clean plan to update files, send steering, /goal and hindsight updates';
 await writeSideQuestion(sideQuestionKey(parentId),{
  history:[],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{
   question:qText,
   answer:'',
   error:'',
   turnId:'turn-9409',
   startedAt:oneHourSeventeenMinAgo,
  },
 });
 // Even if localStorage still had `active: true, startedAt: 1h17m ago`, clean warm state has the completed answer:
 sessionMock.current={id:sideId,question:qText,harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0,startedAt:oneHourSeventeenMinAgo};
 warmMock.current.set(parentId,{
  history:[{id:`btw:${sideId}:4`,question:qText,answer:'1. Adopt EthLib module + @[expose] public section convention.',userEventId:'turn-9409'}],
  latest:sideId,
  clean:true,
 });
 const watchSpy=vi.fn(async()=>{});
 watchMock.fn=watchSpy;
 serverReconcile.fn=async(parent)=>({
  history:warmMock.current.get(parent)?.history??[],
  latest:sideId,
  authoritative:true,
 });
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission={parentId} items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 // Rendered synchronously on frame 0 (no await needed!) and never calls watchBtw or shows "Starting side agent…":
 expect(screen.getByText('Adopt EthLib module + @[expose] public section convention.')).toBeTruthy();
 expect(screen.queryByText(/Starting side agent/)).toBeNull();
 expect(watchSpy).not.toHaveBeenCalled();
 expect(sessionMock.current.active).toBe(false);
 await waitFor(async()=>{
  const healed=await readSideQuestion(sideQuestionKey(parentId));
  expect(healed?.pending).toBeUndefined();
 });
});

it('transitions an idle open /btw panel into busy streaming via the warm fast path when another device asks a follow-up',async()=>{
 const parentId='cross-device-warm-parent';
 const sideId='side-cross-device';
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 const streamMod=await import('../src/stream');
 await writeSideQuestion(sideQuestionKey(parentId),{
  history:[{id:`btw:${sideId}:1`,question:'First question?',answer:'First answer.'}],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
 });
 sessionMock.current={id:sideId,question:'First question?',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0};
 warmMock.current.set(parentId,{
  history:[{id:`btw:${sideId}:1`,question:'First question?',answer:'First answer.'}],
  latest:sideId,
  clean:true,
 });
 let streamNotify:((event:any)=>void)|undefined;
 const streamSpy=vi.spyOn(streamMod,'streamMission').mockImplementation((_id,cb)=>{streamNotify=cb as any;return ()=>{};});
 const muxSpy=vi.spyOn(streamMod,'isMultiplexSyncActive').mockReturnValue(true);
 const reconcileSpy=vi.fn(async(parent:string)=>({
  history:warmMock.current.get(parent)?.history??[],
  latest:sideId,
  authoritative:true,
 }));
 serverReconcile.fn=reconcileSpy;
 watchMock.fn=(_parent,_signal,receive)=>new Promise<void>(()=>{
  receive({type:'start',model:'opencode · builtin/smart',startedAt:'2026-11-06T12:10:00Z'});
  receive({type:'snapshot',text:'Streaming cross-device reply…',narration:[]});
 });
 let handle!:SideQuestionsHandle;
 try{
  render(()=><SideQuestions mission={parentId} items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
  expect(await screen.findByText('First answer.')).toBeTruthy();
  await waitFor(()=>expect(streamNotify).toBeDefined());
  const callsAfterInitialSync=reconcileSpy.mock.calls.length;

  // Another device posts a new question on the existing side mission; warm reducer updates `activeSession` while keeping `clean: true`:
  const activeSession={id:sideId,question:'Cross-device follow-up?',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:1,startedAt:'2026-11-06T12:10:00Z'};
  sessionMock.current=activeSession;
  warmMock.current.set(parentId,{
   history:[{id:`btw:${sideId}:1`,question:'First question?',answer:'First answer.'}],
   activeSession,
   latest:sideId,
   clean:true,
  });
  streamNotify!({type:'user_message'});

  expect(await screen.findByText('Cross-device follow-up?')).toBeTruthy();
  expect(await screen.findByText('Streaming cross-device reply…')).toBeTruthy();
  // Applied directly from warm state without triggering an extra HTTP reconcile:
  expect(reconcileSpy.mock.calls.length).toBe(callsAfterInitialSync);
 }finally{
  streamSpy.mockRestore();
  muxSpy.mockRestore();
 }
});

it('mints a fresh clientMessageId on Retry after a post-acceptance failure or idempotency_conflict while preserving it for unsent network failures',async()=>{
 const seenIds:string[]=[];
 askMock.fn=async(_m,_q,_ctx,_hist,_sig,receive,_att,_launchSig,clientId)=>{
  seenIds.push(clientId!);
  if(seenIds.length===1)throw new Error("Remote opencode job failed: The inference connection failed temporarily.");
  if(seenIds.length===2)throw Object.assign(new Error('409 {"error":"idempotency_conflict","message":"Idempotency-Key was already used with a different request payload"}'),{notSent:true});
  if(seenIds.length===3)throw Object.assign(new Error('Connection interrupted — your question was not sent. Retry to send it.'),{notSent:true});
  receive({type:'done',answer:'Recovered cleanly.'});
 };
 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="retry-turn-id-discipline" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 await handle.ask('Check babylon progress');
 await screen.findByText("Couldn’t complete side question");
 fireEvent.click(screen.getByRole('button',{name:'Retry'}));
 await screen.findByText(/idempotency_conflict/);
 expect(seenIds[1]).not.toBe(seenIds[0]);
 fireEvent.click(screen.getByRole('button',{name:'Retry'}));
 await screen.findByText(/your question was not sent/);
 expect(seenIds[2]).not.toBe(seenIds[1]);
 fireEvent.click(screen.getByRole('button',{name:'Retry'}));
 await screen.findByText('Recovered cleanly.');
 expect(seenIds[3]).toBe(seenIds[2]);
});

it('clears a persisted pending error banner when server reconciliation returns the auto-recovered answer',async()=>{
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 await writeSideQuestion(sideQuestionKey('23bad383-5b27-4b83-9a84-d86d34223509'),{
  history:[],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:{
   question:'où en est le run sur babylon ?',
   answer:'',
   turnId:'8652b679-ee6e-4b49-9429-b09ec99e08a9',
   error:'409 {"error":"idempotency_conflict","message":"Idempotency-Key was already used with a different request payload"}',
   notSent:true,
  },
 });
 serverReconcile.fn=async()=>({
  history:[{
   id:'btw:fc153ce6-2a61-43a6-8e2f-e01cbc263661:274',
   question:'où en est le run sur babylon ?',
   answer:'Oui, ça a nettement progressé ces deux dernières heures sur babylon.',
   at:'2026-11-07T04:47:37Z',
   userEventId:'8652b679-ee6e-4b49-9429-b09ec99e08a9',
  }],
  authoritative:true,
 });
 render(()=><SideQuestions mission="23bad383-5b27-4b83-9a84-d86d34223509" items={[]} ref={()=>{}} onTransfer={()=>{}}/>);
 await screen.findByText('Oui, ça a nettement progressé ces deux dernières heures sur babylon.');
 await waitFor(()=>expect(screen.queryByText(/idempotency_conflict/)).toBeNull());
});

it('preserves and reopens /btw automatically when switching across mission tabs and top-level pages unless explicitly closed',async()=>{
 const {Show}=await import('solid-js');
 const {FilePanelProvider,FilePanelButton}=await import('../src/FilePanel');
 const {readSideQuestion,sideQuestionKey}=await import('../src/sideQuestionStorage');
 vi.stubGlobal('fetch',vi.fn(async()=>response([{type:'done',answer:'Mission A side answer.'}])));

 const missionRecord=(id:string)=>({id,project:'orb',status:'active' as const,title:id,history:[],created_at:'',updated_at:''});
 const [missionOpen,setMissionOpen]=createSignal<string|null>('mission-a');
 // Simulate `fileScopeMission()` arriving asynchronously after `missionOpen` on archived/project missions:
 const [scopeMission,setScopeMission]=createSignal<ReturnType<typeof missionRecord>|undefined>(undefined);

 const view=render(()=>(
  <div class="app">
   <FilePanelProvider missionOpen={missionOpen()} scope={{mission:scopeMission()}}>
    <FilePanelButton/>
    <Show when={missionOpen()??undefined} keyed>
     {id=><SideQuestions mission={id} items={[]} ref={()=>{}} onTransfer={()=>{}}/>}
    </Show>
   </FilePanelProvider>
  </div>
 ));
 const appEl=view.container.querySelector('.app') as HTMLElement;
 const sideAside=()=>view.container.querySelector('.btw-sidebar') as HTMLElement;

 // Open /btw on mission-a before scope.mission finishes hydrating:
 fireEvent.click(screen.getByRole('button',{name:'Side question'}));
 expect(await screen.findByPlaceholderText('Ask a side question…')).toBeTruthy();
 expect(appEl.dataset.filesOpen).toBe('true');
 expect(sideAside().style.display).not.toBe('none');

 // Late `fileScopeMission()` resolution for the SAME mission must not close `/btw`:
 setScopeMission(missionRecord('mission-a'));
 expect(appEl.dataset.filesOpen).toBe('true');
 expect(sideAside().style.display).not.toBe('none');

 const sideInput=screen.getByPlaceholderText('Ask a side question…');
 fireEvent.input(sideInput,{target:{value:'Keep me open across tabs'}});
 fireEvent.keyDown(sideInput,{key:'Enter'});
 expect(await screen.findByText('Mission A side answer.')).toBeTruthy();

 // 1. Switch from mission-a (/btw open) to mission-b (/btw never opened):
 setMissionOpen('mission-b');
 setScopeMission(missionRecord('mission-b'));
 await waitFor(()=>expect(appEl.dataset.filesOpen).toBe('false'));
 expect(sideAside().style.display).toBe('none');
 expect((await readSideQuestion(sideQuestionKey('mission-a')))?.open).toBe(true);

 // 2. Switch back to mission-a: /btw reopens automatically on frame 0 without clicking again!
 setMissionOpen('mission-a');
 setScopeMission(undefined);
 expect(appEl.dataset.filesOpen).toBe('true');
 expect(sideAside().style.display).not.toBe('none');
 expect(await screen.findByText('Mission A side answer.')).toBeTruthy();
 setScopeMission(missionRecord('mission-a'));
 expect(appEl.dataset.filesOpen).toBe('true');

 // 3. Switch from mission-a (/btw open) to a top-level page (Inbox / New Agent: missionOpen = null) and back:
 setMissionOpen(null);
 setScopeMission(undefined);
 expect(appEl.dataset.filesOpen).toBe('false');
 expect(sideAside().style.display).toBe('none');
 expect((await readSideQuestion(sideQuestionKey('mission-a')))?.open).toBe(true);

 setMissionOpen('mission-a');
 expect(appEl.dataset.filesOpen).toBe('true');
 expect(sideAside().style.display).not.toBe('none');
 expect(await screen.findByText('Mission A side answer.')).toBeTruthy();

 // 4. Cold reload (in-memory hints cleared, IndexedDB still holds open: true) with missionOpen passed:
 view.unmount();
 resetSideQuestionStorageForTest();
 const coldView=render(()=>(
  <div class="app">
   <FilePanelProvider missionOpen={missionOpen()} scope={{mission:missionRecord(missionOpen()??'mission-a')}}>
    <FilePanelButton/>
    <Show when={missionOpen()??undefined} keyed>
     {id=><SideQuestions mission={id} items={[]} ref={()=>{}} onTransfer={()=>{}}/>}
    </Show>
   </FilePanelProvider>
  </div>
 ));
 const coldApp=coldView.container.querySelector('.app') as HTMLElement;
 await waitFor(()=>expect(coldApp.dataset.filesOpen).toBe('true'));
 expect(await screen.findByText('Mission A side answer.')).toBeTruthy();

 // 5. Explicit user close persists closed across tab switches:
 fireEvent.click(screen.getByRole('button',{name:'Close side questions'}));
 expect(coldApp.dataset.filesOpen).toBe('false');
 await waitFor(async()=>expect((await readSideQuestion(sideQuestionKey('mission-a')))?.open).toBe(false));
 setMissionOpen('mission-b');
 setMissionOpen('mission-a');
 await new Promise(r=>setTimeout(r,20));
 expect(coldApp.dataset.filesOpen).toBe('false');
});

it('windows long /btw history to the latest 20 turns on open and expands on demand',async()=>{
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 const turns=Array.from({length:45},(_,i)=>({
  id:`turn-${i+1}`,
  question:`Side question #${i+1}`,
  answer:`Side answer #${i+1}`,
  at:`2026-11-09T12:${String(Math.floor(i/60)).padStart(2,'0')}:${String(i%60).padStart(2,'0')}Z`,
 }));
 await writeSideQuestion(sideQuestionKey('mission-windowed'),{
  history:turns,
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:null,
 });
 serverReconcile.fn=async()=>({history:turns,authoritative:true});
 const view=render(()=><SideQuestions mission="mission-windowed" items={[]} ref={()=>{}} onTransfer={()=>{}}/>);
 await screen.findByText('Side answer #45');
 expect(view.container.querySelectorAll('[data-side-turn]').length).toBe(20);
 expect(screen.queryByText('Side answer #25')).toBeNull();
 expect(screen.getByText('Side answer #26')).toBeTruthy();

 const loadMore=screen.getByRole('button',{name:'Load earlier side questions (25)'});
 fireEvent.click(loadMore);
 await waitFor(()=>expect(view.container.querySelectorAll('[data-side-turn]').length).toBe(40));
 expect(screen.getByText('Side answer #6')).toBeTruthy();
 expect(screen.queryByText('Side answer #5')).toBeNull();

 fireEvent.click(screen.getByRole('button',{name:'Load earlier side questions (5)'}));
 await waitFor(()=>expect(view.container.querySelectorAll('[data-side-turn]').length).toBe(45));
 expect(screen.getByText('Side answer #1')).toBeTruthy();
 expect(screen.queryByRole('button',{name:/Load earlier side questions/})).toBeNull();
});

it('shows SideQuestionSkeleton instead of premature empty-state copy while cold server reconciliation is in flight',async()=>{
 let resolveServer!:(v:{history:Array<{id:string;question:string;answer:string;at:string}>;authoritative:boolean})=>void;
 serverReconcile.fn=()=>new Promise(resolve=>{resolveServer=resolve;});

 let handle!:SideQuestionsHandle;
 render(()=><SideQuestions mission="mission-cold-skeleton" items={[]} ref={h=>handle=h} onTransfer={()=>{}}/>);
 handle.open();

 expect(await screen.findByRole('status',{name:'Loading side questions'})).toBeTruthy();
 expect(screen.queryByText(/Ask a question or give the side agent a task/)).toBeNull();

 await waitFor(()=>expect(typeof resolveServer).toBe('function'));
 resolveServer({
  history:[{id:'btw:m1:1',question:'Cold question',answer:'Hydrated side answer',at:'2026-11-09T12:00:00Z'}],
  authoritative:true,
 });
 expect(await screen.findByText('Hydrated side answer')).toBeTruthy();
 expect(screen.queryByRole('status',{name:'Loading side questions'})).toBeNull();
});

it('binds Cmd/Ctrl+K and .btw-sidebar exclusively to the active slot in a multi-mission keep-alive pool',async()=>{
 const {For}=await import('solid-js');
 const {FilePanelProvider,FilePanelButton}=await import('../src/FilePanel');
 const {sideQuestionKey,writeSideQuestion}=await import('../src/sideQuestionStorage');
 const fs=await import('node:fs');
 const path=await import('node:path');

 await writeSideQuestion(sideQuestionKey('mission-keep-a'),{
  history:[{id:'a-1',question:'Question A',answer:'Mission A exclusive side answer.',at:'2026-11-11T10:00:00Z'}],
  draft:'',
  model:'opencode · builtin/smart',
  open:false,
  docked:true,
  pending:null,
 });
 await writeSideQuestion(sideQuestionKey('mission-keep-b'),{
  history:[{id:'b-1',question:'Question B',answer:'Mission B exclusive side answer.',at:'2026-11-11T10:05:00Z'}],
  draft:'',
  model:'opencode · builtin/smart',
  open:true,
  docked:true,
  pending:null,
 });

 const missionRecord=(id:string)=>({id,project:'orb',status:'active' as const,title:id,history:[],created_at:'',updated_at:''});
 const [slots]=createSignal(['mission-keep-a','mission-keep-b']);
 const [missionOpen,setMissionOpen]=createSignal<string|null>('mission-keep-a');

 const view=render(()=>(
  <div class="app">
   <FilePanelProvider missionOpen={missionOpen()} scope={{mission:missionOpen()?missionRecord(missionOpen()!):undefined}}>
    <FilePanelButton/>
    <For each={slots()}>{id=>(
     <div class="mission-slot" hidden={missionOpen()!==id}>
      <SideQuestions mission={id} active={missionOpen()===id} items={[]} ref={()=>{}} onTransfer={()=>{}}/>
     </div>
    )}</For>
   </FilePanelProvider>
  </div>
 ));
 const appEl=view.container.querySelector('.app') as HTMLElement;
 const sideAside=()=>view.container.querySelector('.btw-sidebar') as HTMLElement;
 const isMac=/mac|iphone|ipad|ipod/i.test(navigator.platform);
 const pressBtwShortcut=()=>fireEvent.keyDown(window,{key:'k',code:'KeyK',metaKey:isMac,ctrlKey:!isMac});

 // 1. mission-keep-a starts with open=false even though mission-keep-b (mounted in background!) has open=true:
 await waitFor(()=>expect(appEl.dataset.filesOpen).toBe('false'));
 expect(sideAside().style.display).toBe('none');
 expect(screen.queryByText('Mission B exclusive side answer.')).toBeNull();

 // 2. Switch to mission-keep-b -> mission-keep-b's open=true restores immediately:
 setMissionOpen('mission-keep-b');
 await waitFor(()=>expect(appEl.dataset.filesOpen).toBe('true'));
 expect(await screen.findByText('Mission B exclusive side answer.')).toBeTruthy();
 expect(screen.queryByText('Mission A exclusive side answer.')).toBeNull();

 // 3. Switch BACK to kept-alive mission-keep-a -> mission-keep-b's panel hides, and shortcut opens mission-keep-a's own /btw!
 setMissionOpen('mission-keep-a');
 await waitFor(()=>expect(appEl.dataset.filesOpen).toBe('false'));
 expect(screen.queryByText('Mission B exclusive side answer.')).toBeNull();

 pressBtwShortcut();
 await waitFor(()=>expect(appEl.dataset.filesOpen).toBe('true'));
 expect(await screen.findByText('Mission A exclusive side answer.')).toBeTruthy();
 expect(screen.queryByText('Mission B exclusive side answer.')).toBeNull();
 expect(sideAside().querySelectorAll('.btw-panel').length).toBe(1);

 // 4. Leave missions (Inbox / New Agent) -> unregisters side handle and hides .btw-sidebar:
 setMissionOpen(null);
 await waitFor(()=>expect(appEl.dataset.filesOpen).toBe('false'));
 expect(sideAside().style.display).toBe('none');
 expect(screen.queryByRole('button',{name:'Side question'})).toBeNull();

 // 5. CSS invariant: half-screen (<1150px) floating .file-panel uses opaque var(--bg) and respects --sb-w:
 const css=fs.readFileSync(path.resolve(__dirname,'../src/styles.css'),'utf8');
 expect(css).toContain('width:min(780px,calc(100vw - var(--sb-w)));background:var(--bg)');
});





