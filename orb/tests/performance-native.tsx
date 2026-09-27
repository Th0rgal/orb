import {render} from 'solid-js/web';
import {createSignal} from 'solid-js';
import {NativeInteraction} from '../src/NativeInteraction';
import {followInteraction} from '../src/nativeInteractionStream';
import {Transcript,buildTranscript,applyStreamEvent} from '../src/Transcript';
import '../src/styles.css';
const [items,setItems]=createSignal<any[]>([]),[view,setView]=createSignal('idle');
const pending={kind:'tool',key:'q',callId:'q',name:'ui_native_request',done:false,args:{method:'questions',params:{questions:[{id:'q',question:'Performance fixture: keep typing',options:[{label:'Later'}]}]}}};
const [requests,setRequests]=createSignal([pending]);
render(()=><main style={{padding:'32px','max-width':'900px',margin:'auto'}}><h2>Orb Performance Lab</h2><p>Synthetic content · native Tauri channels · no model calls</p><NativeInteraction mission="performance-fixture" active={view()==='question'} remote items={requests()}/><Transcript items={items()}/></main>,document.getElementById('root')!);
let received=0;const errors:string[]=[];
const stop=followInteraction('performance-empty',()=>received++,e=>errors.push(String(e)));
const quantile=(xs:number[],q:number)=>[...xs].sort((a,b)=>a-b)[Math.min(xs.length-1,Math.floor(xs.length*q))];
Object.assign(window,{perfHarness:{
 status:()=>({received,errors,native:!!(window as any).__TAURI_INTERNALS__,visibility:document.visibilityState}),
 question(){setView('question');},
 async stableQuestion(){setView('question');await new Promise(r=>setTimeout(r,50));const input=document.querySelector('.native-question input.s-input') as HTMLInputElement;input.focus();input.value='A draft';input.dispatchEvent(new Event('input',{bubbles:true}));input.setSelectionRange(2,5);for(let i=0;i<20;i++){setRequests(structuredClone([pending]));await new Promise(r=>setTimeout(r,50));}return {same:document.querySelector('.native-question input.s-input')===input,focused:document.activeElement===input,value:input.value,selection:[input.selectionStart,input.selectionEnd]};},
 async transcript(turns=300,updates=100){
  setView('transcript');const events:any[]=[];for(let i=0;i<turns;i++)events.push({type:'user_message',data:{id:`u${i}`,content:`Inspect module ${i}`}},{type:'tool_call',data:{tool_call_id:`t${i}`,name:'read',args:{path:`src/module${i}.ts`}}},{type:'tool_result',data:{tool_call_id:`t${i}`,result:'Read complete'}},{type:'assistant_message',data:{id:`a${i}`,content:`## Module ${i}\n\nThe implementation preserves **request identity** and cancellation.\n\n- One subscription\n- No idle traffic\n\n\`\`\`typescript\nconst result = await subscribe(${i});\n\`\`\``}});
  let t=performance.now();const replay=buildTranscript(events);const replayMs=performance.now()-t;t=performance.now();setItems(replay);void document.body.offsetHeight;const mountMs=performance.now()-t;
  await new Promise(r=>setTimeout(r,1000));let added=0,removed=0;const observer=new MutationObserver(rows=>{for(const row of rows){added+=row.addedNodes.length;removed+=row.removedNodes.length;}});observer.observe(document.getElementById('root')!,{subtree:true,childList:true});const times:number[]=[];
  for(let i=0;i<updates;i++){t=performance.now();setItems(v=>applyStreamEvent(v,{type:'text_delta',data:{content:' A streamed fragment.'}}));void document.body.offsetHeight;times.push(performance.now()-t);await new Promise(r=>setTimeout(r,16));}
  observer.disconnect();return {turns,updates,replayMs,mountMs,updateP50:quantile(times,.5),updateP95:quantile(times,.95),updateMax:Math.max(...times),updatesOver16ms:times.filter(t=>t>16).length,added,removed,nodes:document.querySelectorAll('*').length,visibility:document.visibilityState};
 },stop}});
