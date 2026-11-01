import { cleanup, fireEvent, render, screen, waitFor } from '@solidjs/testing-library';
import { afterEach, expect, it, vi } from 'vitest';
import { createSignal } from 'solid-js';
import { Composer } from '../src/composer/Composer';
import { SideQuestions, type SideQuestionsHandle } from '../src/SideQuestionPanel';
import { askSide, boundedHistory, sideContext } from '../src/sideQuestionClient';
const serverReconcile=vi.hoisted(()=>({
 fn:async(_parent:string,local:any[])=>({history:local} as {history:any[];activeSession?:any;latest?:string}),
 reconnect:async(_parent:string,sideId:string)=>({id:sideId,question:'Running side question',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0}),
}));
const watchMock=vi.hoisted(()=>({fn:async(_parent:string,_signal:AbortSignal,_receive:(e:any)=>void)=>{}}));
const queueFollowUpMock=vi.hoisted(()=>({enabled:false,fn:vi.fn()}));
vi.mock('../src/btwAgent',async()=>{const client=await import('../src/sideQuestionClient');return {askBtwAgent:client.askSide,btwSession:()=>undefined,btwActivities:()=>[],btwItems:()=>[],btwThoughts:()=>thoughts.value,stopBtw:async()=>{},watchBtw:(parent:string,signal:AbortSignal,receive:(e:any)=>void)=>watchMock.fn(parent,signal,receive),reconnectBtwSession:(parent:string,sideId:string)=>serverReconcile.reconnect(parent,sideId),reconcileBtwServerHistory:(parent:string,local:any[])=>serverReconcile.fn(parent,local),get queueBtwFollowUp(){return queueFollowUpMock.enabled?queueFollowUpMock.fn:undefined;},isSyntheticRemoteAssistantNote:(text:string)=>/^Remote (?:node '[^']+'|\w+) job [0-9a-f-]{36} /.test(text)};});
const thoughts=vi.hoisted(()=>({value:[] as {kind:'think';key:string;text:string;done:boolean}[]}));
const storage=vi.hoisted(()=>new Map<string,unknown>());
vi.mock('../src/composerDrafts',()=>({
 readComposerDraft:async(key:string)=>storage.get('draft:'+key),
 saveComposerDraft:async(key:string,value:unknown)=>{storage.set('draft:'+key,structuredClone(value));},
 readSideThread:async(key:string)=>storage.get('thread:'+key),
 saveSideThread:async(key:string,value:unknown)=>{storage.set('thread:'+key,structuredClone(value));},
}));
afterEach(()=>{cleanup();vi.unstubAllGlobals();storage.clear();thoughts.value=[];queueFollowUpMock.enabled=false;queueFollowUpMock.fn.mockReset();watchMock.fn=async()=>{};serverReconcile.fn=async(_parent:string,local:any[])=>({history:local});serverReconcile.reconnect=async(_parent:string,sideId:string)=>({id:sideId,question:'Running side question',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0});});
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
