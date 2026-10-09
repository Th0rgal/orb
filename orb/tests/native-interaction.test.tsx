import {describe,it,expect,vi,beforeEach,afterEach} from 'vitest';
import {render,screen,fireEvent,waitFor,cleanup} from '@solidjs/testing-library';
import {createSignal} from 'solid-js';
import {MissionGlyph} from '../src/MissionGlyph';
import {NativeInteraction} from '../src/NativeInteraction';
import {api} from '../src/api';
vi.mock('../src/api',async importOriginal=>({...await importOriginal<typeof import('../src/api')>(),api:vi.fn()}));
import {composerModes,modePrompt} from '../src/goal';

let emitted:any;
const previousTauri=(window as any).__TAURI__;
beforeEach(()=>{(window as any).__TAURI__={core:{Channel:class {onmessage=(value:any)=>{};constructor(){emitted=this;}}}};});
afterEach(()=>{(window as any).__TAURI__=previousTauri;});
function transport(read:(command:string,args?:any)=>Promise<any>){return async(command:string,args:any)=>{
 if(command==='local_interaction_subscribe'){args.onEvent.onmessage(await read('local_interaction',{}));return 1;}
 if(command==='local_interaction_unsubscribe')return;
 return read(command,args);
};}
describe('native plan interactions',()=>{
 it('only exposes Plan when the destination confirms support',()=>{
  for(const harness of ['codex','claudecode','opencode','grok','gemini','chatgpt']) {
   expect(composerModes(harness).some(m=>m.id==='plan')).toBe(false);
  }
  for (const harness of ['codex', 'claudecode', 'vibe']) {
   expect(composerModes(harness,true).some(m=>m.id==='plan')).toBe(true);
  }
  expect(composerModes('vibe',true).map(mode=>mode.id)).toEqual(['plan']);
  expect(composerModes('vibe',false)).toEqual([]);
  expect(modePrompt('plan','Build it')).toBe('/plan Build it');
 });
 it('recovers a pending question and sends its native request identity only once',async()=>{
  let pending:any={id:'native-1',method:'questions',params:{questions:[{id:'greeting',question:'Which greeting?',options:[{label:'Hello',description:'English'}]}]}};
  const invoke=vi.fn(async(cmd:string,args:any)=>{
   if(cmd==='local_interaction')return pending;
   expect(args).toEqual({id:'mission',requestId:'native-1',answer:{answers:{greeting:{answers:['Hello']}}}});
   pending=null;return null;
  });
  const host=window as any;const previous=host.__TAURI_INTERNALS__;host.__TAURI_INTERNALS__={invoke:transport(invoke)};
  try{
   render(()=><><MissionGlyph missionId="mission" status="awaiting_user"/><NativeInteraction mission="mission" active/></>);
   await screen.findByText('Which greeting?');
   expect(document.querySelector('.mission-glyph')?.getAttribute('title')).toBe('Waiting for your reply');
   fireEvent.click(screen.getByRole('radio'));
   fireEvent.click(screen.getByRole('button',{name:'Continue'}));
   await waitFor(()=>expect(screen.queryByRole('button',{name:'Continue'})).toBeNull());
   expect(invoke.mock.calls.filter(([cmd])=>cmd==='local_interaction_answer')).toHaveLength(1);
   expect(document.querySelector('.mission-glyph')?.getAttribute('title')).toBe('Ready for a follow-up');
  }finally{cleanup();host.__TAURI_INTERNALS__=previous;}
 });
 it('switching from a custom answer to an option clears the custom field',async()=>{
  const invoke=vi.fn(async()=>({id:'custom',method:'questions',params:{questions:[{id:'q',question:'Where?',options:[{label:'Locally'}]}]}}));
  const host=window as any;const previous=host.__TAURI_INTERNALS__;host.__TAURI_INTERNALS__={invoke:transport(invoke)};
  try{
   render(()=><NativeInteraction mission="mission" active/>);
   const input=await screen.findByRole('textbox',{name:'Other answer: Where?'});
   fireEvent.input(input,{target:{value:'Elsewhere'}});
   expect((input as HTMLInputElement).value).toBe('Elsewhere');
   fireEvent.click(screen.getByRole('radio'));
   expect((input as HTMLInputElement).value).toBe('');
  }finally{cleanup();host.__TAURI_INTERNALS__=previous;}
 });
 it('does not accept a plan until explicitly clicked',async()=>{
  const invoke=vi.fn(async(cmd:string)=>cmd==='local_interaction'?{id:'plan-1',method:'plan',params:{plan:'Create hello.txt'}}:null);
  const host=window as any;const previous=host.__TAURI_INTERNALS__;host.__TAURI_INTERNALS__={invoke:transport(invoke)};
  try{
   render(()=><NativeInteraction mission="mission" active/>);
   await screen.findByText('Create hello.txt');
   expect(invoke.mock.calls.every(([cmd])=>cmd==='local_interaction')).toBe(true);
   fireEvent.click(screen.getByRole('button',{name:'Implement plan'}));
   await waitFor(()=>expect(invoke).toHaveBeenCalledWith('local_interaction_answer',{id:'mission',requestId:'plan-1',answer:{action:'accept',feedback:''}}));
  }finally{cleanup();host.__TAURI_INTERNALS__=previous;}
 });
 it('retains an expired remote request with an error and sends JSON to the exact tool call',async()=>{
  vi.mocked(api).mockResolvedValue({delivered:false});
  try {
   render(()=><NativeInteraction mission="remote" active remote items={[{kind:'tool',key:'r',callId:'native-remote',name:'ui_native_request',args:{method:'plan',params:{}},done:false}]}/>);
   fireEvent.click(await screen.findByRole('button',{name:'Implement plan'}));
   await screen.findByRole('alert');
   expect(api).toHaveBeenCalledWith('/api/control/tool_result',expect.objectContaining({headers:{'Content-Type':'application/json'},body:JSON.stringify({tool_call_id:'native-remote',name:'ui_native_request',result:{action:'accept',feedback:''}})}));
   expect(screen.getByRole('button',{name:'Implement plan'})).toBeTruthy();
  } finally {cleanup();}
 });
 it('sends requested changes without accepting execution',async()=>{
  const invoke=vi.fn(async(cmd:string)=>cmd==='local_interaction'?{id:'revise',method:'plan',params:{}}:null);
  const host=window as any;const previous=host.__TAURI_INTERNALS__;host.__TAURI_INTERNALS__={invoke:transport(invoke)};
  try {
   render(()=><NativeInteraction mission="mission" active/>);
   await screen.findByRole('button',{name:'Request changes'});
   fireEvent.input(screen.getByRole('textbox',{name:'Requested changes'}),{target:{value:'Use a single file'}});
   fireEvent.click(screen.getByRole('button',{name:'Request changes'}));
   await waitFor(()=>expect(invoke).toHaveBeenCalledWith('local_interaction_answer',{id:'mission',requestId:'revise',answer:{action:'revise',feedback:'Use a single file'}}));
  } finally {cleanup();host.__TAURI_INTERNALS__=previous;}
 });

});

 it('shares request replacement and cancellation with the sidebar',()=>{
  const question={kind:'tool' as const,key:'q',callId:'q',name:'ui_native_request',args:{method:'questions',params:{questions:[]}},done:false};
  const [items,setItems]=createSignal([question]);
  const [active,setActive]=createSignal(true);
  const {container}=render(()=><><MissionGlyph missionId="shared" status="awaiting_user"/><NativeInteraction mission="shared" active={active()} remote items={items()}/></>);
  const label=()=>container.querySelector('.mission-glyph')?.getAttribute('title');
  expect(label()).toBe('Waiting for your reply');
  setItems([{...question,callId:'plan',args:{method:'plan',params:{questions:[]}}}]);
  expect(label()).toBe('Approval requested');
  setActive(false);
  expect(label()).toBe('Ready for a follow-up');
  expect(container.querySelector('.native-question')).toBeNull();
  cleanup();
 });


describe('question focus during refresh',()=>{
 const question={id:'focus-request',method:'questions',params:{questions:[{id:'q',question:'Phone number?',options:[{label:'Later'}]}]}};
 it('preserves the focused custom answer and selection across native events',async()=>{
  vi.useFakeTimers();
  const host=window as any,previous=host.__TAURI_INTERNALS__;
  const invoke=vi.fn(async()=>JSON.parse(JSON.stringify(question)));
  host.__TAURI_INTERNALS__={invoke:transport(invoke)};
  try {
   render(()=><NativeInteraction mission="focus-local" active/>);
   await vi.advanceTimersByTimeAsync(0);
   const input=screen.getByRole('textbox',{name:'Other answer: Phone number?'}) as HTMLInputElement;
   input.focus();fireEvent.input(input,{target:{value:'+33 612345678'}});input.setSelectionRange(4,7);
   for(let i=0;i<20;i++)emitted.onmessage(structuredClone(question));
   await vi.advanceTimersByTimeAsync(6000);
   expect(invoke).toHaveBeenCalledTimes(1);
   expect(screen.getByRole('textbox',{name:'Other answer: Phone number?'})).toBe(input);
   expect(document.activeElement).toBe(input);
   expect(input.value).toBe('+33 612345678');
   expect([input.selectionStart,input.selectionEnd]).toEqual([4,7]);
  } finally {cleanup();host.__TAURI_INTERNALS__=previous;vi.useRealTimers();}
 });
 it('preserves focus across remote snapshots but updates changed requests',()=>{
  const item={kind:'tool' as const,key:'focus-tool',callId:question.id,name:'ui_native_request',args:question,done:false};
  const [items,setItems]=createSignal([item]);
  try {
   render(()=><NativeInteraction mission="focus-remote" active remote items={items()}/>);
   const input=screen.getByRole('textbox',{name:'Other answer: Phone number?'}) as HTMLInputElement;
   input.focus();fireEvent.input(input,{target:{value:'My answer'}});input.setSelectionRange(2,5);
   for(let i=0;i<5;i++)setItems(JSON.parse(JSON.stringify([item])));
   expect(document.activeElement).toBe(input);
   expect([input.selectionStart,input.selectionEnd]).toEqual([2,5]);
   expect(input.value).toBe('My answer');
   setItems([{...item,args:{...question,params:{questions:[{id:'q',question:'Updated question?',options:[]}]}}}]);
   expect(screen.getByRole('textbox',{name:'Other answer: Updated question?'})).toBeTruthy();
   setItems([{...item,callId:'next-request'}]);
   expect((screen.getByRole('textbox',{name:'Other answer: Phone number?'}) as HTMLInputElement).value).toBe('');
  } finally {cleanup();}
 });
});

it('shows a subscription failure even without a pending request and allows retry',async()=>{
 const host=window as any,previous=host.__TAURI_INTERNALS__,previousTauri=host.__TAURI__;
 const invoke=vi.fn().mockRejectedValueOnce('permission denied').mockResolvedValue(1);
 host.__TAURI_INTERNALS__={invoke};host.__TAURI__={core:{Channel:class {onmessage=()=>{};}}};
 try {
  render(()=><NativeInteraction mission="retry" active/>);
  expect((await screen.findByRole('alert')).textContent).toContain('permission denied');
  fireEvent.click(screen.getByRole('button',{name:'Retry'}));
  await waitFor(()=>expect(invoke).toHaveBeenCalledTimes(2));
  expect(screen.queryByRole('alert')).toBeNull();
 } finally {cleanup();host.__TAURI_INTERNALS__=previous;host.__TAURI__=previousTauri;}
});

it('keeps a new native request that arrives before the previous answer resolves',async()=>{
 const host=window as any,previous=host.__TAURI_INTERNALS__;
 host.__TAURI_INTERNALS__={invoke:transport(async(command:string)=>{
  if(command==='local_interaction')return {id:'first',method:'questions',params:{questions:[{id:'q',question:'Choose storage',options:[{label:'Local'}]}]}};
  if(command==='local_interaction_answer')emitted.onmessage({id:'second',method:'plan',params:{plan:'Save locally'}});
 })};
 try{
  render(()=><NativeInteraction mission="consecutive-requests" active/>);
  fireEvent.click(await screen.findByRole('radio',{name:'Local'}));
  fireEvent.click(screen.getByRole('button',{name:'Continue'}));
  await screen.findByRole('button',{name:'Implement plan'});
  expect(screen.getByText('Save locally')).toBeTruthy();
 }finally{cleanup();host.__TAURI_INTERNALS__=previous;}
});
